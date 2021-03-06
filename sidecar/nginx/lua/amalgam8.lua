local cjson     = require("cjson.safe")
local math     = require("math")
local balancer = require("ngx.balancer")

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG
local ngx_INFO = ngx.INFO
local ngx_WARN = ngx.WARN
local ngx_var = ngx.var
local ngx_shared = ngx.shared
local tostring = tostring

--TODO: This code has been tested with a single worker only
-----With multiple workers, we might need a read-write lock on the
-----shared state (a8_instances, a8_rules) so that workers do not see
-----intermediate state of system while an update is in progress. That could
-----potentially result in erroneous routing. Since the sidecar operates as a
-----"sidecar", along side the app, one worker should be sufficient in most
-----situations. Hence, no effort has been made to protect accesses to the
-----global shared state with locks. The performance of lua-resty-lock needs
-----to be evaluated at high load.
local Amalgam8 = { _VERSION = '0.3.0' }

local delay_action, abort_action, trace_action = 1, 2, 3
local default_timeout, default_retries = 60, 0

local function is_valid_string(input)
   if input and type(input) == 'string' and input ~= '' then
      return true
   else
      return false
   end
end


local function is_valid_number(input)
   if input and type(input) == 'number' then
      return true
   else
      return false
   end
end


local function get_name_and_tags()
   local service_name = os.getenv("A8_SERVICE")

   if not is_valid_string(service_name) then
      return nil, nil, "A8_SERVICE environment variable is either empty or not set"
   end

   local tags = {}
   local name, version
   for x,y,z in string.gmatch(service_name, '([^:]+)(:?(.*))') do
      name = x
      version = z
      break
   end

   return name, version, nil
   -- if version then
   --    for t in string.gmatch(version, '([^:]+)') do
   --       table.insert(tags, t)
   --    end
   -- end
   
   -- return name, tags, nil
end


local function add_cookie(cookie)
   local cookies = ngx.header["Set-Cookie"] or {}
    if type(cookies) == "string" then
        cookies = {cookies}
    end
    table.insert(cookies, cookie)
    ngx.header['Set-Cookie'] = cookies
end


local function create_cookie_version(route_backend)
   local name = route_backend.name or ""
   local tags = route_backend.tags or ""
   if route_backend.tags then tags = table.concat(route_backend.tags, ",") end
   return name.."-"..tags
end


local function create_instance(i)
   if i.status ~= "UP" then return nil end
   local instance = {}

   if i.tags then 
      instance.tags = table.concat(i.tags, ",")
   end

   instance.type = i.endpoint.type
   if not i.endpoint.type then
      instance.type = 'http'
   end
   for x,y,z in string.gmatch(i.endpoint.value, '([^:]+)(:?(.*))') do
      instance.host = x
      instance.port = tonumber(z)
      break
   end
   if not instance.port then
      if instance.type == 'http' then
         instance.port = 80
      elseif instance.type == 'https' then
         instance.port = 443
      else
         ngx_log(ngx_WARN, "ignoring endpoint " .. instance.host .. ", missing port")
         return nil
      end
   end
   -- TODO: add support for hostnames in endpoints
   return instance
end


local function compare_rules_descending(a, b)
   return a.priority > b.priority
end


-- local function compare_backends(a, b)
--    return a.weight < b.weight
-- end


local function match_header_value(req_headers, header_name, header_val_pattern)
   local header_value = req_headers[header_name]
   if header_value then
      -- ngx_log(ngx_DEBUG, "match_header_value: header_name "..header_name.." value "..header_value.." pattern "..header_val_pattern)
      local m, err = ngx.re.match(header_value, header_val_pattern, "o")
      if m then
         -- ngx_log(ngx_DEBUG, "header matched for "..header_name.." returning true")
         return true
      end
   end
   return false
end


local function match_headers(req_headers, rule)
   -- r1 = cjson.encode(rule)
   if not rule.match then
      -- ngx_log(ngx_DEBUG, "match_headers: No rule.match block for rule "..r1)
      return true
   end --source matched (earlier), destination matched.
   if rule.match.all then
      -- ngx_log(ngx_DEBUG, "match_headers: rule has match.all block "..r1)
      for k, v in pairs(rule.match.all) do
         -- ngx_log(ngx_DEBUG, "match_headers: matching header "..k.." value "..v.." for rule.match.all "..r1)
         if not match_header_value(req_headers, k, v) then return false end
      end
   end

   if rule.match.any then
      -- all conditions should hold true (AND)
      -- atleast one should pass. (OR).
      local any_match = false

      for k, v in pairs(rule.match.any) do
         if match_header_value(req_headers, k, v) then
            any_match = true
            break
         end
      end
      if not any_match then return false end
   end

   if rule.match.none then
      -- none of the conditions should match
      for k, v in pairs(rule.match.none) do
         if match_header_value(req_headers, k, v) then return false end
      end
   end

   return true
end


local function match_tags(src_tag_string, dst_tag_set) --assumes both are not nil
   -- local empty_src_tags = (string.len(src_tag_string) == 0)
   -- local empty_dst_tags = (not dst_tag_set)
   local match = true
   for _, t in ipairs(dst_tag_set) do
      if not string.find(src_tag_string, t, 1, true) then
         match = false
         break
      end
   end
   return match
end

local function check_and_preprocess_match(myname, mytags, match_type, match_sub_block)
   if not match_sub_block then return false, nil end

   local match_cond = nil
   local is_my_tag_empty = (string.len(mytags) == 0)
   local match_found = false

   for _, m in ipairs(match_sub_block) do
      local check1 = false
      local check2 = false

      if m.source then 
         local empty_src_tags = (not m.source.tags)
         local empty_src_name = (not m.source.name)
         local tags = m.source.tags

         --src has a name
         -- name match, with empty rule src tags
         -- src tags and my tags matched
         check1 = (not empty_src_name and (m.source.name == myname) and (empty_src_tags or (not is_my_tag_empty and match_tags(mytags, tags))))
         -- src has no service name. But it should have tags
         check2 = (empty_src_name and (not is_my_tag_empty and match_tags(mytags, tags)))
      else
         -- empty source implies wildcard source. Rule match found for all/any. continue collecting other fields.
         if match_type ~= "none" then check1 = true end
      end
      
      if check1 or check2 then
         match_found = true
         if m.headers then
            match_cond = {}
            for k,v in pairs(m.headers) do
               match_cond[k]=v
            end
         end
         return match_found, match_cond -- consider only the first match in the array of blocks containing source/headers
      end
   end

   return match_found, match_cond
end


local function is_rule_for_me(myname, mytags, rule)
   --by default we assume rule is for us if the
   -- A. (match.(all|any|none).source is nil) OR
   -- (B. (the source field in all|any sub match matches service name and tags) AND
   --  C. (the source field in none sub match DOES NOT match service name and tags))
   -- If the source field has no service name but tags are provided, then we compare our tags
   -- with the source tags.
   ---- If our service tags are empty, then try next source block
   -- if source field has service name but no service tags, then the rule applies to us if service name matches
   -- if source field has no service name but has service tags, then the rule applies to us if tags match
   ----if our service has no tags, then try next source block

   if not rule.match then return true end

   local match = {}
   local all_headers, any_headers, none_headers
   local all_res, any_res, none_res
 
   if rule.match.source or rule.match.headers then
      match["source"] = rule.match.source
      match["headers"] = rule.match.headers
      if not rule.match.all then
         rule.match.all = {}
      end
      table.insert(rule.match.all, match)
   end

   all_res, all_headers = check_and_preprocess_match(myname, mytags, "all", rule.match.all)
   any_res, any_headers = check_and_preprocess_match(myname, mytags, "any", rule.match.any)
   none_res, none_headers = check_and_preprocess_match(myname, mytags, "none", rule.match.none)

   -- either all block or any block must match and nothing in none block should match.
   -- empty blocks amount to nil. We have already taken care of all blocks being empty by checking for empty rule.match
   local res = ((all_res and rule.match.all) or (any_res and rule.match.any)) and not (none_res and rule.match.none)
   if res then
      if not all_headers and not any_headers and not none_headers then
         rule.match = nil
      else
         rule.match = {
            all = all_headers,
            any = any_headers,
            none = none_headers
         }
      end
   end
   return res
end


local function create_rule(rule, myname, mytags)
   -- no match implies wildcard rule from * to *
   if not is_rule_for_me(myname, mytags, rule) then
      return nil
   end

   if not rule.priority then
      rule.priority = 0
   end

   if not rule.route and not rule.actions then
      return nil
   end

   -- rule can have only route or action. Not both.
   if rule.route and rule.actions then
      return nil
   end

   -- set default weights for backends where no weight is specified
   ---- Take the leftover weight and distribute it equally among
   ---- unweighted backends
   if rule.route then
      if not rule.route.backends then return nil end
      local sum = 0.0
      local prev = 0.0
      local unweighted = 0
      for _, b in ipairs(rule.route.backends) do
         -- add a name to every backend, so that the cookie_version_name is created properly.
         -- otherwise, we will end up having cookie_version names like -v1, -v2, which will not
         -- match any backend name stored in the browser's version cookie.
         if not b.name then
            b.name = rule.destination
         end
         if b.weight then
            sum = sum + b.weight
         else
            unweighted = unweighted + 1
         end
      end

      if sum > 1.0 then
         ngx_log(ngx_ERR, "sum of weights has exceeded 1.0: " .. prev)
         return nil
      end
      local balance = 1.0 - sum
      for _, b in ipairs(rule.route.backends) do
         if not b.weight then
            b.weight = 1.0 * balance/unweighted
         end
         b.weight_order = prev + b.weight
         prev = b.weight_order         
      end
      if prev > 1.0 then
         ngx_log(ngx_ERR, "total weights has exceeded 1.0: " .. prev)
         return nil
      end

   end

   if rule.actions then
      for _, a in ipairs(rule.actions) do
         if a.action == "delay" then
            a.action= delay_action
         elseif a.action == "abort" then
            a.action= abort_action
         elseif a.action == "trace" then
            a.action= trace_action
         else
            ngx_log(ngx_ERR, "Unknown action provided in rule "..a.action)
            return nil
         end
      end
      -- if rule.tags then
      --    local a8_recipe_id
      --    for _, t in ipairs(rule.tags) do
      --       a8_recipe_id = string.match(t, '^a8_recipe_id=(.+)')
      --       if a8_recipe_id then
      --          rule.a8_recipe_id = a8_recipe_id
      --          break
      --       end
      --    end
      -- end
   end
   return rule
end


local function get_unpacked_val(shared_dict, key)
   local serialized = shared_dict:get(key)
   if serialized then
      return cjson.decode(serialized)
   end
   return nil
end


local function reset_state()
   ngx_shared.a8_instances:flush_all()
   ngx_shared.a8_instances:flush_expired()
   ngx_shared.a8_routes:flush_all()
   ngx_shared.a8_routes:flush_expired()
   ngx_shared.a8_actions:flush_all()
   ngx_shared.a8_actions:flush_expired()
end


function Amalgam8:new()
   o = {}
   setmetatable(o, self)
   self.__index = self

   local myname, mytags, err = get_name_and_tags()
   if err then
      return nil, err
   end

   self.myname = myname
   self.mytags = mytags
   return o, nil
end


-- a8_instances stores registry info
-- a8_rules stores rules data, keyed by destination. Each entry is an array of
-- rules for that destination, ordered by priority.

-- Select rule from a8_rules[destination]
-- select backend and obtain the backend's tags
-- then do delay/abort if backend's tags match
-- then fetchInstances of the backend based on its tags and load balance.

-- Two functions are needed for rule matching:
--  get_instances(service_name, tags)
--  match_instance_tags(instance, tags)
function Amalgam8:update_state(input)
   local a8_instances = {}
   local a8_routes = {}
   local a8_actions = {}
   local err

   if input.instances then
      for _, e in ipairs(input.instances) do
         if e.service_name ~= self.myname then
            local instance = create_instance(e)
            if instance then
               if not a8_instances[e.service_name] then
                  a8_instances[e.service_name] = {}
               end
               table.insert(a8_instances[e.service_name], instance)
            end
         end
       end

       for service, instances in pairs(a8_instances) do
          serialized = cjson.encode(instances)
          _, err = ngx_shared.a8_instances:set(service, serialized)
          if err then
             err = "failed to update instances for service:"..service..":"..err
             return err
          end
       end
   end

   if input.rules then
      for _, r in ipairs(input.rules) do
         if r.route then
            local rule = create_rule(r, self.myname, self.mytags)
            if rule then
               --- destination need not be the same as the service_name.
               --- One can have URIs in the destination as well. 
               if not a8_routes[r.destination] then
                  a8_routes[r.destination] = {}
               end
               table.insert(a8_routes[r.destination], rule)
            end
         elseif r.actions then
            local rule = create_rule(r, self.myname, self.mytags)
            if rule then
               --- destination need not be the same as the service_name.
               --- One can have URIs in the destination as well. 
               if not a8_actions[r.destination] then
                  a8_actions[r.destination] = {}
               end
               table.insert(a8_actions[r.destination], rule)
            end
         end
      end

      for destination, rset in pairs(a8_routes) do
         table.sort(rset, compare_rules_descending)
         serialized = cjson.encode(rset)
         _, err = ngx_shared.a8_routes:set(destination, serialized)
         if err then
            err = "failed to update routes for service:"..service..":"..err
            return err
         end
      end

      for destination, aset in pairs(a8_actions) do
         table.sort(aset, compare_rules_descending)
         serialized = cjson.encode(aset)
         _, err = ngx_shared.a8_actions:set(destination, serialized)
         if err then
            err = "failed to update actions for service:"..service..":"..err
            return err
         end
      end
   end

   return nil
end


function Amalgam8:proxy_admin()
   if ngx.req.get_method() == "PUT" or ngx.req.get_method() == "POST" then
      ngx.req.read_body()

      local input, err = cjson.decode(ngx.req.get_body_data())
      if err then
         ngx.status = ngx.HTTP_BAD_REQUEST
         ngx_log(ngx_ERR, "error decoding input json: " .. err)
         ngx.say("error decoding input json: " .. err)
         ngx.exit(ngx.status)
      end

      -- if table.getn(input.instances) == 0 and table.getn(input.rules) == 0 then
      --   ngx_log(ngx_ERR, "Received empty input from caller. Ignoring..")
      --   ngx.exit(400)
      -- end

      -- TODO: locking in multi-worker context.
      reset_state()
      if #input.instances == 0 and #input.rules == 0 then
         ngx.exit(ngx.HTTP_OK)
      end

      err = self:update_state(input)
      if err then
         ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
         ngx_log(ngx_ERR, "error updating proxy: " .. err)
         ngx.say("error updating internal state: " .. err)
         ngx.exit(ngx.status)
      end

      ---START DEBUG
      -- local state = {
      --    instances = {},
      --    routes = {},
      --    actions = {}
      -- }

      -- local instance_keys = ngx_shared.a8_instances:get_keys()
      -- local route_keys = ngx_shared.a8_routes:get_keys()
      -- local action_keys = ngx_shared.a8_actions:get_keys()

      -- for _,key in ipairs(instance_keys) do
      --    state.instances[key] = get_unpacked_val(ngx_shared.a8_instances, key)
      -- end
      -- for _,key in ipairs(route_keys) do
      --    state.routes[key] = get_unpacked_val(ngx_shared.a8_routes, key)
      -- end
      -- for _,key in ipairs(action_keys) do
      --    state.actions[key] = get_unpacked_val(ngx_shared.a8_actions, key)
      -- end

      -- local output, err = cjson.encode(state)
      -- ngx_log(ngx_DEBUG, output)
      ---END DEBUG

      ngx.exit(ngx.HTTP_OK)
   elseif ngx.req.get_method() == "GET" then
      local state = {
         instances = {},
         routes = {},
         actions = {}
      }

      -- TODO: This fetches utmost 1024 keys only
      local instance_keys = ngx_shared.a8_instances:get_keys()
      local route_keys = ngx_shared.a8_routes:get_keys()
      local action_keys = ngx_shared.a8_actions:get_keys()

      for _,key in ipairs(instance_keys) do
         state.instances[key] = get_unpacked_val(ngx_shared.a8_instances, key)
      end
      for _,key in ipairs(route_keys) do
         state.routes[key] = get_unpacked_val(ngx_shared.a8_routes, key)
      end
      for _,key in ipairs(action_keys) do
         state.actions[key] = get_unpacked_val(ngx_shared.a8_actions, key)
      end

      local output, err = cjson.encode(state)
      if err then
         ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
         ngx.say("error encoding state as JSON:" .. err)
         ngx_log(ngx_ERR, "error encoding state as JSON:" .. err)
         nex.exit(ngx.status)
      end
      ngx.header["content-type"] = "application/json"
      ngx.say(output)
      ngx.exit(ngx.HTTP_OK)
   else
      return ngx.exit(ngx.HTTP_BAD_REQUEST)
   end
end


---select the route rule to apply
---select the backend from the route rule (and instances)
---select the action rule to apply
---apply the actions from the action rule based on tags
---pass on to balancer_by_lua for actual routing
function Amalgam8:apply_rules()
   local destination = ngx.var.service_name
   ngx.var.a8_upstream_name = destination

   local instances = get_unpacked_val(ngx_shared.a8_instances, destination)
   if not instances or #instances == 0 then
      ngx.status = ngx.HTTP_NOT_FOUND
      ngx.exit(ngx.status)
   end

   local routes = get_unpacked_val(ngx_shared.a8_routes, destination)
   local actions = get_unpacked_val(ngx_shared.a8_actions, destination)
   local headers = ngx.req.get_headers()

   local selected_instances = {}
   local selected_route = nil
   local selected_actions = nil
   local selected_backend = nil
   local cookie_version = ngx.var.cookie_version --check for version cookie

   if routes then
      for _, r in ipairs(routes) do --rules are ordered by decreasing priority
         -- r1 = cjson.encode(r)
         -- ngx_log(ngx_DEBUG, "Matching route "..r1)
         if match_headers(headers, r) then
            selected_route = r.route
            break
         end
      end
      -- r1 = cjson.encode(selected_route)
      -- ngx_log(ngx_DEBUG, "selected route "..r1)
      if not selected_route then
         ngx.status = 412 -- Precondition failed
         ngx.exit(ngx.status)
      end

      if #selected_route.backends == 1 then
         selected_backend = selected_route.backends[1]
      elseif cookie_version then --check if backend still exists
         for _, b in ipairs(selected_route.backends) do
            -- concatenate backend name and tags
            if cookie_version == create_cookie_version(b) then
               selected_backend = b
               break
            end
         end
      end

      if not selected_backend then -- cookie_version did not match any backend
         local weight = math.random()
         for _,b in ipairs(selected_route.backends) do --backends are ordered by increasing weight
            if weight < b.weight_order then
               selected_backend = b
               break
            end
         end
      end

      if not selected_backend.tags then
         if selected_backend.name and selected_backend.name ~= destination then
            selected_instances = get_unpacked_val(ngx_shared.a8_instances, selected_backend.name)
         end
         if not selected_backend.name or not instances then
            ngx.status = ngx.HTTP_NOT_FOUND
            ngx.exit(ngx.status)
         end
      else
         if selected_backend.name and selected_backend.name ~= destination then
            instances = get_unpacked_val(ngx_shared.a8_instances, selected_backend.name)
            if not instances then
               ngx.status = ngx.HTTP_NOT_FOUND
               ngx.exit(ngx.status)
            end
         else
            selected_backend.name = destination
         end         
         for _, i in ipairs(instances) do
            if i.tags and match_tags(i.tags, selected_backend.tags) then
               table.insert(selected_instances, i)
            end
         end
      end

      ngx.var.a8_upstream_name = selected_backend.name

      if not selected_instances or #selected_instances == 0 then
         ngx.status = ngx.HTTP_NOT_FOUND
         ngx.exit(ngx.status)
      end

      if selected_backend.host then
         ngx.var.a8_upstream_host = selected_backend.host
      end

      --set the version cookie      
      local selected_version =  create_cookie_version(selected_backend)
      if cookie_version then --delete old cookie
         add_cookie("version=; Path=/" .. selected_backend.name .. "; Expires=" .. ngx.cookie_time(0))
      end
      --set the cookie to the version we selected
      add_cookie("version="..selected_version.."; Path=/"..selected_backend.name)

   else
      selected_instances = instances
      ngx.var.a8_upstream_name = destination
   end

   ngx.ctx.a8_backend = selected_backend
   ngx.ctx.a8_upstreams = selected_instances

   -- We need to know if this is a http or https instance. And the assumption here is that all instances in the pool are of same type.
   -- So pick the first instance and get its instance type. This variable will be used by the proxy_pass directive
   ngx.var.a8_service_type = selected_instances[1].type

   if actions then
      -- ngx_log(ngx_DEBUG, destination.." has actions "..tostring(#actions))
      for _, a in ipairs(actions) do --rules are ordered by decreasing priority
         if match_headers(headers, a) then
            selected_actions = a.actions
            break
         end
      end
      if not selected_actions then ngx.exit(0) end -- proceed to next stage
      -- ngx_log(ngx_DEBUG, "matched action "..cjson.encode(selected_actions).." for "..destination)

      -- Actions are performed on the backends (not specific instances of the backend). It would be
      -- nice to inject faults for specific instances but we can't do ngx.sleep in balancer_by_lua 
      for _,sa in ipairs(selected_actions) do
         if not sa.tags or (selected_backend and match_tags(table.concat(selected_backend.tags), sa.tags)) then
            -- ngx_log(ngx_DEBUG, "action type "..tostring(sa.action).." tags matched for "..destination)
            if sa.action <= abort_action then
               -- ngx_log(ngx_DEBUG, "executing action type "..tostring(sa.action).." for "..destination)
               if math.random() < sa.probability then
                  -- ngx_log(ngx_DEBUG, "action type "..tostring(sa.action).." probability matched for "..destination)
                  if sa.action == delay_action then
                     ngx.sleep(sa.duration)
                  elseif sa.action == abort_action then
                     ngx.exit(sa.return_code)
                  end
               end
            elseif sa.action == trace_action then
               ngx.var.a8_trace_key = sa.log_key
               ngx.var.a8_trace_value = sa.log_value
            end
         end
      end
   end

end


function Amalgam8:load_balance()
   local selected_instances = ngx.ctx.a8_upstreams
   local selected_backend = ngx.ctx.a8_backend
   local timeout = nil
   local retries = nil

   if selected_backend then
      if selected_backend.timeout and selected_backend.timeout > 0 then
         timeout = selected_backend.timeout
         local ok, err = balancer.set_timeouts(timeout, timeout, timeout)
         if not ok then
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
            ngx_log(ngx_ERR, "failed to set timeouts"..err)
            ngx.exit(ngx.status)
         end
      end

      -- TODO: Failover and retries
      -- if selected_backend.retries and selected_backend.retries > 0 then
      --    retries = selected_backend.retries
      --    if not ngx.ctx.tries then ngx.ctx.tries = 0 end
      --    local state_name, status_code = balancer.get_last_failure()
      --    ngx_log(ngx_DEBUG, "Setting retries to ",retries," attempts of which ",ngx.ctx.tries," attempts have been made with last status ",state_name," error code ",status_code)
      --    if ngx.ctx.tries <= retries then
      --       local ok, err = balancer.set_more_tries(1)
      --       if err then
      --          ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
      --          ngx_log(ngx_ERR, "failed to set retries"..err)
      --          ngx.exit(ngx.status)
      --       end
      --    else
      --       ngx.exit(status_code)
      --    end
      --    ngx.ctx.tries = ngx.ctx.tries + 1
      -- end
   end

   --TODO: refactor. Need different LB functions
   local upstream = selected_instances[math.random(#selected_instances)]
   ngx.var.a8_upstream_tags = upstream.tags
   -- ngx_log(ngx_DEBUG, "Selecting instance "..upstream.host..":"..upstream.port)
   ok, err = balancer.set_current_peer(upstream.host, upstream.port)
   if not ok then
      ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
      ngx_log(ngx_ERR, "failed to set current peer"..err)
      ngx.exit(ngx.status)
   end
end


function Amalgam8:get_myname()
   return self.myname
end


function Amalgam8:get_mytags()
   return self.mytags
end


return Amalgam8

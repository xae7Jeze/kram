--[[
simple implementation of mapping conference names to ids and vice versa

- needs 2 shared lua dicts defined in global nginx scope
lua_shared_dict conf2Id 5m;
lua_shared_dict id2Conf 5m;
- integrates in nginx location block with content_by_lua_file directive
  for example
  server {
      location = /api/confMap {
        content_by_lua_file /etc/nginx/lua/confMap.lua;
      }
  }
Author: github.com/xae7Jeze
--]]

-- ttl for dictionary entries
local expireTime = 28800
-- range for conference ids
local minPin = 1000
local maxPin = 99999999

function mapConf2Id (Conf)
  local conf2Id = ngx.shared.conf2Id
  local id2Conf = ngx.shared.id2Conf
  local id
  if Conf == nil then
    return nil,nil,"e_conf_arg_nil"
  end
  if type(Conf) == "table" then
    Conf = Conf[#Conf]
  end
  if #Conf > 1000 or not string.match (Conf, '^[_%w.@-]+$') then
    return nil,nil,"e_conf_name_invalid"
  end
  local conf = string.lower(Conf)
  id = conf2Id:get(conf)
  if id ~= nil then 
    if string.match (id,'^%d+$') and tonumber(id,10) >= minPin and  tonumber(id,10) <= maxPin then
       id2Conf:set(id,conf,expireTime)
       conf2Id:set(conf,id,expireTime)
      return conf,id,nil
    else
      conf2Id:delete(conf)
      Id2Conf:delete(id)
    end
  end
  -- create mapping    
  math.randomseed (os.time())
  while true do
    id = math.random(minPin,maxPin)
    if id2Conf:get(id) == nil then
       id2Conf:set(id,conf,expireTime)
       conf2Id:set(conf,id,expireTime)
       return Conf,id,nil
     end
   end
end

function mapId2Conf(id)
  local conf
  local conf2Id = ngx.shared.conf2Id
  local id2Conf = ngx.shared.id2Conf
  if id == nil then
    return nil,nil,"e_id_arg_nil"
  end
  if not (string.match (id,'^%d+$') and tonumber(id,10) >= minPin and  tonumber(id,10) <= maxPin) then
    return nil,nil,"e_conf_id_invalid"
  end
  conf = id2Conf:get(id)
  if conf == nil then
    return nil,id,"e_conf_not_found"
  end
  if #conf > 1000 and not string.match (conf, '^[_%w.@-]+$') then
    conf2Id:delete(conf)
    Id2Conf:delete(id)
    return nil,id,"e_conf_not_found"
  end
  id2Conf:set(id,conf,expireTime)
  conf2Id:set(conf,id,expireTime)
  return conf,id,nil
end



local args, err = ngx.req.get_uri_args()
local conference =  args['conference'] 
local id =  args['id'] 
local error
-- nothing is given
if conference == nil and id == nil then
  ngx.status = ngx.HTTP_NOT_ALLOWED
  ngx.header["Content-Type"] = 'application/json'
  ngx.print('{"message":"No conference or id provided","conference":false,"id":false}')
  return
end
-- conference is given
if conference ~= nil then
  conference,id,error = mapConf2Id (conference)
  if error == nil and conference ~= nil and id ~= nil then
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = 'application/json'
    ngx.print('{"message":"Successfully retrieved conference mapping","id":',id,',"conference":"',conference,'"}')
  else
    ngx.status = ngx.HTTP_BAD_REQUEST
    ngx.print('')
  end
  return
end
-- id is given
if id ~= nil then
  conference,id,error = mapId2Conf(id)
  if error == nil and conference ~= nil and id ~= nil then
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = 'application/json'
    ngx.print('{"message":"Successfully retrieved conference mapping","id":',id,',"conference":"',conference,'"}')
    return
  end
  if error == "e_conf_not_found" then
    ngx.status = ngx.HTTP_OK
    ngx.header["Content-Type"] = 'application/json'
    ngx.print('{"message":"No conference mapping was found","id":',id,',"conference":false}')
    return
  end
  ngx.status = ngx.HTTP_BAD_REQUEST
  ngx.print('')
  return
end

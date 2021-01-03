-- Borrowed from https://github.com/mahyarnajibi/fast-rcnn-torch

local GeneralUtils = torch.class('GeneralUtils')


function GeneralUtils:__init()
  return self
end

function GeneralUtils:table2str(tab,internal_node)
  local str = ''
  for k,v in pairs(tab) do
    local cur_k = k
    local cur_v = v
    if type(k) == 'table' then
        cur_k = self:table2str(k,true)
    end
    if type(v) == 'table' then
        cur_v = self:table2str(v,true)
    end
    if type(v) == 'boolean' then
      if v== false then
        cur_v = 'false'
      else
        cur_v = 'true'
      end
    end
    if type(cur_v)~='function' then
      if internal_node then
        str = str .. cur_k .. ': ' .. cur_v .. ' ' 
      else
        str = str .. cur_k .. ': ' .. cur_v .. '\n'
      end
    end
  end
  return str
end

function GeneralUtils:shuffle(dim,tensor)
  local randperm = torch.randperm(tensor:size(dim)):long()
  return tensor:index(dim,randperm)
end

function GeneralUtils:tableDeepCopy(tab)
  if type(tab)=='userdata' and tab.clone ~= nil then return tab:clone() end -- for dealing with tensors
  if type(tab) ~= 'table' and type(tab) ~= 'cdata' then return tab end
  local res
  if type(tab) == 'table' then
    res = setmetatable({}, getmetatable(tab))
    for k, v in pairs(tab) do res[self:tableDeepCopy(k)] = self:tableDeepCopy(v) end
  else -- We are dealing with tds
    res = tds.Hash()
    for k, v in pairs(tab) do res[self:tableDeepCopy(k)] = self:tableDeepCopy(v) end
  end
  return res
end

function GeneralUtils:logical2ind(logical)
  if logical:numel() == 0 then
    return torch.LongTensor()
  end
  return torch.range(1,logical:numel())[logical:gt(0)]:long()
end

function GeneralUtils:makeWholeNetworkParallel(model)
  local nGPU = math.min(cutorch.getDeviceCount(),config.nGPU)
  local curmodel = nn.DataParallelTable(1)
  for i=1, nGPU do
      cutorch.setDevice(i)
      curmodel:add(model:clone():cuda(), i)
    end
    cutorch.setDevice(1)
    return curmodel
end


function GeneralUtils:recursiveMakeDataParallel(model)
    if model:size() == 1 then
      return model
    end
    for i=1,model:size() do
        local model_i = model:get(i)
        if torch.type(model_i) == 'nn.Sequential' or torch.type(model_i) == 'nn.ConcatTable' then
          -- Make it parallel
          print('Coverting sub-module to DataParallelTable')
          local nGPU = math.min(cutorch.getDeviceCount(),config.nGPU)
          local model_single = model_i
          local curmodel = nn.DataParallelTable(1)
          for i=1, nGPU do
            cutorch.setDevice(i)
            if i==1 then 
              curmodel:add(model_single:clone():cuda(), i)
            else 
              curmodel:add(model_single:clone():cuda(), i)
            end
          end
          cutorch.setDevice(1)
          -- replace the layer
          model.modules[i] = curmodel
        else
          if model_i.size then -- It is a container
            self:recursiveMakeDataParallel(model_i)
          end
        end
    end
    return model
end

function GeneralUtils:_recursiveUndoDataParallel(model)

end

function GeneralUtils:visualize_detections(im,boxes,scores,thresh,cl_names)
  local ok = pcall(require,'qt')
  if not ok then
    error('You need to run visualize_detections using qlua')
  end
  require 'qttorch'
  require 'qtwidget'

  -- select best scoring boxes without background
  local max_score,idx = scores[{{},{2,-1}}]:max(2)

  local idx_thresh = max_score:gt(thresh)
  max_score = max_score[idx_thresh]
  idx = idx[idx_thresh]

  local r = torch.range(1,boxes:size(1)):long()
  local rr = r[idx_thresh]
  if rr:numel() == 0 then
    error('No detections with a score greater than the specified threshold')
  end
  local boxes_thresh = boxes:index(1,rr)
  
  local keep = self:nms(torch.cat(boxes_thresh:float(),max_score:float(),2),0.3)
  
  boxes_thresh = boxes_thresh:index(1,keep)
  max_score = max_score:index(1,keep)
  idx = idx:index(1,keep)

  local num_boxes = boxes_thresh:size(1)
  local widths  = boxes_thresh[{{},3}] - boxes_thresh[{{},1}]
  local heights = boxes_thresh[{{},4}] - boxes_thresh[{{},2}]

  local x,y = im:size(3),im:size(2)
  local w = qtwidget.newwindow(x,y,"Fast R-CNN for Torch!")
  
  local qtimg = qt.QImage.fromTensor(im)
  w:image(0,0,x,y,qtimg)
  local fontsize = 16

  w:setcolor(200/255,130/255,200/255,1)
  w:rectangle(20,20,120,55)
  w:fill()
  w:stroke()

  w:setcolor(0,0,0,1)
  w:fill(false)
  w:rectangle(20,20,120,55)
  w:stroke()
  w:moveto(30,40)
  w:setfont(qt.QFont{serif=true,italic=true,size=fontsize,bold=true})
  w:setcolor(qt.QColor("#000000"))
  w:show('Click on')
  w:moveto(30,40+fontsize+5)
  w:show('boxes!')
  for i=1,num_boxes do
    local x,y = boxes_thresh[{i,1}],boxes_thresh[{i,2}]
    local width,height = widths[i], heights[i]
    w:rectangle(x,y,width,height)

  end
  w:setcolor("#7CFF00")
  w:setlinewidth(2)
  w:stroke()

  qt.connect(w.listener,
    'sigMousePress(int,int,QByteArray,QByteArray,QByteArray)',
    function(x,y)
        for i = 1, boxes_thresh:size(1) do
          if x>boxes_thresh[i][1] and x < boxes_thresh[i][3] and y>boxes_thresh[i][2] and y<boxes_thresh[i][4] then
            w:setcolor(200/255,130/255,200/255,1)
            w:rectangle(20,20,120,55)
            w:fill()
            w:stroke()

            w:setcolor(0,0,0,1)
            w:fill(false)
            w:rectangle(20,20,120,55)
            w:stroke()

            w:moveto(30,40)
            w:setfont(qt.QFont{serif=true,italic=true,size=fontsize,bold=true})
            w:setcolor(qt.QColor("#000000"))
            w:show(cl_names[idx[i]])
            w:moveto(30,40+fontsize+5)
            w:show(string.format('%2.2f',max_score[i]))
            w:stroke()
            w:fill(false)
          end
        end
    end );

  return w
end

function GeneralUtils:saveDataParallel(filename, model)
  -- Borrowed from https://github.com/soumith/imagenet-multiGPU.torch/
   if torch.type(model) == 'nn.DataParallelTable' then
      torch.save(filename, self:cleanDPT(model))
   elseif torch.type(model) == 'nn.Sequential' then
      local temp_model = nn.Sequential()
      for i, module in ipairs(model.modules) do
         if torch.type(module) == 'nn.DataParallelTable' then
            temp_model:add(self:cleanDPT(module))
         else
            temp_model:add(module)
         end
      end
      torch.save(filename, temp_model)
   else
      error('This saving function only works with Sequential or DataParallelTable modules.')
   end
end

function GeneralUtils:loadDataParallel(filename, nGPU)
  -- Borrowed from https://github.com/soumith/imagenet-multiGPU.torch/
   local model = torch.load(filename)
   if torch.type(model) == 'nn.DataParallelTable' then
      return self:makeDataParallel(model:get(1):float(), nGPU)
   elseif torch.type(model) == 'nn.Sequential' then
      for i,module in ipairs(model.modules) do
         if torch.type(module) == 'nn.DataParallelTable' then
            model.modules[i] = self:makeDataParallel(module:get(1):float(), nGPU)
         end
      end
      return model
   else
      error('The loaded model is not a Sequential or DataParallelTable module.')
   end
end

function GeneralUtils:makeDataParallel(model, nGPU)
-- borrowed from https://github.com/soumith/imagenet-multiGPU.torch/
   if config.nGPU > 1 then
      print('converting module to nn.DataParallelTable')
      assert(nGPU <= cutorch.getDeviceCount(), 'number of GPUs less than nGPU specified')
      local model_single = model
      model = nn.DataParallelTable(1)
      for i=1, nGPU do
         cutorch.setDevice(i)
         model:add(model_single:clone():cuda(), i)
      end
      cutorch.setDevice(config.GPU_ID)
   end
   return model
end

function GeneralUtils:keep_top_k(boxes,top_k)
  -- This function is borrowed from https://github.com/fmassa/object-detection.torch
  local X = joinTable(boxes,1)
  if X:numel() == 0 then
    return
  end
  local scores = X[{{},-1}]:sort(1,true)
  local thresh = scores[math.min(scores:numel(),top_k)]
  for i=1,#boxes do
    local bbox = boxes[i]
    if bbox:numel() > 0 then
      local idx = torch.range(1,bbox:size(1)):long()
      local keep = bbox[{{},-1}]:ge(thresh)
      idx = idx[keep]
      if idx:numel() > 0 then
        boxes[i] = bbox:index(1,idx)
      else
        boxes[i]:resize()
      end
    end
  end
  return boxes, thresh
end

function GeneralUtils:cleanDPT(module)
  --  Borrowed from https://github.com/soumith/imagenet-multiGPU.torch/
   local newDPT = nn.DataParallelTable(1)
   cutorch.setDevice(config.GPU_ID)
   newDPT:add(module:get(1), config.GPU_ID)
   return newDPT
end


function GeneralUtils:recursiveResizeAsCopyTyped(t1,t2,type)
  -- This function is borrowed from https://github.com/fmassa/object-detection.torch
  if torch.type(t2) == 'table' then
    t1 = (torch.type(t1) == 'table') and t1 or {t1}
    for key,_ in pairs(t2) do
      t1[key], t2[key] = self:recursiveResizeAsCopyTyped(t1[key], t2[key], type)
    end
  elseif torch.isTensor(t2) then
    local type = type or t2:type()
    t1 = torch.isTypeOf(t1,type) and t1 or torch.Tensor():type(type)
    t1:resize(t2:size()):copy(t2)
  else
    error("expecting nested tensors or tables. Got "..
    torch.type(t1).." and "..torch.type(t2).." instead")
  end
  return t1, t2
end


function GeneralUtils:flipBoundingBoxes(bbox, im_width)
  -- This function is borrowed from https://github.com/fmassa/object-detection.torch
  if bbox:dim() == 1 then 
    local tt = bbox[1]
    bbox[1] = im_width-bbox[3]+1
    bbox[3] = im_width-tt     +1
  else
    local tt = bbox[{{},1}]:clone()
    bbox[{{},1}]:fill(im_width+1):add(-1,bbox[{{},3}])
    bbox[{{},3}]:fill(im_width+1):add(-1,tt)
  end
end

function GeneralUtils:concat(t1,t2,dim)
    -- This function is borrowed from https://github.com/fmassa/object-detection.torch
  local out
  assert(t1:type() == t2:type(),'tensors should have the same type')
  if t1:dim() > 0 and t2:dim() > 0 then
    dim = dim or t1:dim()
    out = torch.cat(t1,t2,dim)
  elseif t1:dim() > 0 then
    out = t1:clone()
  else
    out = t2:clone()
  end
  return out
end



function GeneralUtils:boxoverlap(a,b)
  -- This function is borrowed from https://github.com/fmassa/object-detection.torch
  local b = b.xmin and {b.xmin,b.ymin,b.xmax,b.ymax} or b
    
  local x1 = a:select(2,1):clone()
  x1[x1:lt(b[1])] = b[1] 
  local y1 = a:select(2,2):clone()
  y1[y1:lt(b[2])] = b[2]
  local x2 = a:select(2,3):clone()
  x2[x2:gt(b[3])] = b[3]
  local y2 = a:select(2,4):clone()
  y2[y2:gt(b[4])] = b[4]
  
  local w = x2-x1+1;
  local h = y2-y1+1;
  local inter = torch.cmul(w,h):float()
  local aarea = torch.cmul((a:select(2,3)-a:select(2,1)+1) ,
                           (a:select(2,4)-a:select(2,2)+1)):float()
  local barea = (b[3]-b[1]+1) * (b[4]-b[2]+1);
  
  -- intersection over union overlap
  local o = torch.cdiv(inter , (aarea+barea-inter))
  -- set invalid entries to 0 overlap
  o[w:lt(0)] = 0
  o[h:lt(0)] = 0
  
  return o
end



function GeneralUtils:nms(boxes, overlap)
  -- This function is borrowed from https://github.com/fmassa/object-detection.torch
    local pick = torch.LongTensor()

    if boxes:numel() == 0 then
      return pick
    end

    local x1 = boxes[{{},1}]
    local y1 = boxes[{{},2}]
    local x2 = boxes[{{},3}]
    local y2 = boxes[{{},4}]
    local s = boxes[{{},-1}]
    
    local area = boxes.new():resizeAs(s):zero()
    area:map2(x2,x1,function(xx,xx2,xx1) return xx2-xx1+1 end)
    area:map2(y2,y1,function(xx,xx2,xx1) return xx*(xx2-xx1+1) end)

    local vals, I = s:sort(1)

    pick:resize(s:size()):zero()
    local counter = 1
    local xx1 = boxes.new()
    local yy1 = boxes.new()
    local xx2 = boxes.new()
    local yy2 = boxes.new()

    local w = boxes.new()
    local h = boxes.new()

    while I:numel()>0 do 
      local last = I:size(1)
      local i = I[last]
      pick[counter] = i
      counter = counter + 1
      if last == 1 then
        break
      end
      I = I[{{1,last-1}}]
      
      xx1:index(x1,1,I)
      xx1:cmax(x1[i])
      yy1:index(y1,1,I)
      yy1:cmax(y1[i])
      xx2:index(x2,1,I)
      xx2:cmin(x2[i])
      yy2:index(y2,1,I)
      yy2:cmin(y2[i])
      
      w:resizeAs(xx2):zero()
      w:map2(xx2,xx1,function(xx,xxx2,xxx1) return math.max(xxx2-xxx1+1,0) end)
      h:resizeAs(yy2):zero()
      h:map2(yy2,yy1,function(xx,yyy2,yyy1) return math.max(yyy2-yyy1+1,0) end)
      
      local inter = w
      inter:cmul(h)

      local o = h
      xx1:index(area,1,I)
      torch.cdiv(o,inter,xx1+area[i]-inter)
      I = I[o:le(overlap)]
    end

    pick = pick[{{1,counter-1}}]
    return pick
end


ReaderCache={}
local removeDirectory=RemoveDirectory
local doesFileExist=System.doesFileExist
local deleteFile=System.deleteFile
local createDirectory=System.createDirectory
local session=0
local root='ux0:data/noboru/temp/reader'
local reserve=8*1024*1024
local function bounds(page,count,size,direction)
 local first
 if direction<0 then first=math.max(1,math.min(page+2,count)-size+1)
 else first=math.max(1,math.min(page-2,count-size+1)) end
 return first,math.min(count,first+size-1)
end
ReaderCache.bounds=bounds
local function valid(page)
 return page and page.Link~='LoadNext' and page.Link~='LoadPrev'
end
local function remove(path)
 if path and doesFileExist(path) then deleteFile(path) end
end
function ReaderCache.new(pages,parserID,release,loadLocal)
 session=session+1
 if session==1 then removeDirectory(root) end
 createDirectory(root)
 local self={Pages=pages,ParserID=parserID,Release=release,LoadLocal=loadLocal,Active=true,Serial=0,Current=1,Direction=1}
 self.Root=root..'/session-'..session
 createDirectory(self.Root)
 return setmetatable(self,{__index=ReaderCache})
end
function ReaderCache:close()
 self.Active=false
 for i=1,self.Pages.Count or #self.Pages do
  local page=self.Pages[i]
  if page then
   if page.ReaderDownloadKey then Threads.remove(page.ReaderDownloadKey) end
   ParserManager.remove(page);Threads.remove(page)
   if page.Image then self.Release(i) end
  end
 end
 removeDirectory(self.Root)
end
function ReaderCache:move(index,direction)
 self.Current=index
 self.Direction=direction or self.Direction
 self:prune()
end
function ReaderCache:prune()
 local count=self.Pages.Count or #self.Pages
 local first,last=bounds(self.Current,count,30,self.Direction)
 local memFirst,memLast=bounds(self.Current,count,6,self.Direction)
 for i=1,count do
  local page=self.Pages[i]
  if page then
   if page.Image and (i<memFirst or i>memLast) then self.Release(i) end
   if page.ReaderCachePath and (i<first or i>last) then
    if page.ReaderDownloadKey then Threads.remove(page.ReaderDownloadKey) end
    remove(page.ReaderCachePath)
    page.ReaderCachePath=nil;page.ReaderReady=nil
   end
  end
 end
end
function ReaderCache:retry(index)
 local page=self.Pages[index]
 if not page then return end
 if page.ReaderDownloadKey then Threads.remove(page.ReaderDownloadKey) end
 ParserManager.remove(page);Threads.remove(page)
 remove(page.ReaderCachePath)
 page.ReaderCachePath=nil;page.ReaderReady=nil;page.ReaderError=nil;page.ReaderDecodePending=nil;page.ReaderErrorShown=nil;page.Error=nil;page.Done=nil
 if not page.Path and not page.Extract then page.Link=nil end
end
function ReaderCache:ready(page)
 -- This session owns its files; prune/retry invalidate ReaderReady explicitly.
 return page.Path or page.Extract or (page.ReaderReady and page.ReaderCachePath)
end
function ReaderCache:ensure(index,priority)
 local page=self.Pages[index]
 if not valid(page) or page.ReaderError then return false end
 if self:ready(page) then return true end
 if page.ReaderDownloadKey and Threads.check(page.ReaderDownloadKey) then
  if priority then Threads.promote(page.ReaderDownloadKey) end
  return false
 end
 if ParserManager.check(page) then return false end
 if page.Error then page.ReaderError=page.Error;return false end
 if not page.Link then
  if page.Done then page.ReaderError='Parser did not return a page image';return false end
  ParserManager.getPageImage(self.ParserID,page[1],page)
  return false
 end
 if not page.ReaderCachePath then
  self.Serial=self.Serial+1
  page.ReaderCachePath=self.Root..'/page-'..self.Serial..'.image'
 end
 local path=page.ReaderCachePath
 local key={}
 page.ReaderDownloadKey=key
 local task={Type='FileDownload',Link=page.Link,Path=path,Table=page,RequireContent=true,ValidateImage=true,
  OnComplete=function()
   if not self.Active or page.ReaderCachePath~=path then remove(path);return end
   page.ReaderReady=true
   page.ReaderWidth,page.ReaderHeight=System.getPictureResolution(path)
  end,
  OnError=function(message)
   if self.Active and page.ReaderCachePath==path then
    remove(path);page.ReaderError='Page download failed: '..tostring(message):gsub('^.-:%d+:%s*','')
   end
  end}
 if priority then Threads.insertTask(key,task) else Threads.addTask(key,task) end
 return false
end
function ReaderCache:decode(index,priority)
 local page=self.Pages[index]
 if page.ReaderDecodePending or Threads.check(page) then
  if priority then Threads.promote(page) end
  return
 end
 if page.Image or page.ReaderError then return end
 if priority then
  local width,height=page.ReaderWidth,page.ReaderHeight
  if width and height then
   local needed=width*height*4+reserve
   for distance=self.Pages.Count or #self.Pages,1,-1 do
    for _,other in ipairs({index-distance,index+distance}) do
     if Graphics.getFreeMemory()<needed and self.Pages[other] and self.Pages[other].Image then self.Release(other) end
    end
   end
  end
 end
 page.ReaderDecodePending=true
 if page.Path or page.Extract then self.LoadLocal(index)
 else
  local task={Type='Image',Path=page.ReaderCachePath,Table=page,Index='Image',Animated=Settings.AnimatedGif,
   OnError=function(message) page.ReaderError='Image decoding failed: '..tostring(message):gsub('^.-:%d+:%s*','') end}
  if priority then Threads.insertTask(page,task) else Threads.addTask(page,task) end
 end
end
function ReaderCache:load(index)
 if index==self.Current then self:update() end
end
function ReaderCache:update()
 if not self.Active or not valid(self.Pages[self.Current]) then return end
 local count=self.Pages.Count or #self.Pages
 for i=1,count do
  local page=self.Pages[i]
  if page and page.ReaderDecodePending and not Threads.check(page) and not ParserManager.check(page) then
   page.ReaderDecodePending=nil
   if not page.Image then page.ReaderError=page.ReaderError or 'Image could not be decoded; retry this page' end
  end
 end
 self:prune()
 local current=self.Pages[self.Current]
 if current.ReaderError and not current.ReaderErrorShown then
  current.ReaderErrorShown=true
  Notifications.push(current.ReaderError)
 end
 if not self:ensure(self.Current,true) then return end
 if not current.Image and not current.ReaderError then self:decode(self.Current,true);return end
 if self.PlanPage~=self.Current or self.PlanCount~=count or self.PlanDirection~=self.Direction then
  self.Plans={};self.PlanPage=self.Current;self.PlanCount=count;self.PlanDirection=self.Direction
 end
 local function candidates(size)
  if self.Plans[size] then return self.Plans[size] end
  local first,last=bounds(self.Current,count,size,self.Direction)
  local list={self.Current}
  for distance=1,size do
   for _,i in ipairs({self.Current+distance*self.Direction,self.Current-distance*self.Direction}) do
    if i>=first and i<=last and valid(self.Pages[i]) then list[#list+1]=i end
   end
  end
  self.Plans[size]=list
  return list
 end
 -- Decode already downloaded neighbours before waiting on a missing file.
 -- At most one background task is queued; the native async slot remains serial.
 if Threads.isDownloadRunning() then return end
 local nearby=candidates(6)
 for _,i in ipairs(nearby) do
  local page=self.Pages[i]
  if not page.Image and not page.ReaderError and self:ready(page) then
   local width,height=page.ReaderWidth,page.ReaderHeight
   if not width and page.Path and not page.Extract then width,height=System.getPictureResolution(page.Path) end
   if not width or not height or width*height*4+reserve<Graphics.getFreeMemory() then self:decode(i,false);return end
  end
 end
 for _,i in ipairs(nearby) do
  local page=self.Pages[i]
  if not self:ready(page) and not page.ReaderError then self:ensure(i,false);return end
 end
 for _,i in ipairs(candidates(30)) do
  local page=self.Pages[i]
  if not self:ready(page) and not page.ReaderError then self:ensure(i,false);return end
 end
end

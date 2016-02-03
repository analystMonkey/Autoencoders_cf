--This class has very poor design but it does the work. (And Lua is not helping to prototype nice class)
--WARNING : NVI idiom (cf C+++)

local DataLoader = torch.class('DataLoader')


-- Public Interface to implement
function DataLoader:LoadRatings(conf) end
function DataLoader:LoadMetaU  (conf) end
function DataLoader:LoadMetaV  (conf) end


-- Public Interface to call
function DataLoader:LoadData(ratioTraining, conf) 

   -- First initlialize clean storage
   self:__reset()

   self.__ratioTraining = ratioTraining

   print("Step 1 : Loading ratings...")
   self:LoadRatings(conf)

   print("Step 2 : PostProcessig ratings...")
   self:__PostProcessRating()

   --Load MetaData
   print("Step 3 : Load user metadata...")   
   self:LoadMetaU(conf)

   print("Step 4 : Load item metadata...")
   self:LoadMetaV(conf)
   
   print("Step 5 : Saving data in torch format...")
   local data = {train = self.train, test = self.test}
   torch.save(conf.out, data)

   print("Done...")
   return self.train, self.test

end



-- Protected Method (helper)
function DataLoader:AppendOneRating(userId, itemId, rating)

   self.__noRating = self.__noRating + 1

   --store the matrix size by keeping the max Id
   self.__Usize = math.max(self.__Usize, userId)
   self.__Vsize = math.max(self.__Vsize, itemId)


   --store the rating in either the training or testing set
   if math.random() < self.__ratioTraining then

      if self.train.U.data[userId] == nil then self.train.U.data[userId] = nnsparse.DynamicSparseTensor(200) end
      if self.train.V.data[itemId] == nil then self.train.V.data[itemId] = nnsparse.DynamicSparseTensor(200) end 

      self.train.U.data[userId]:append(torch.Tensor{itemId,rating})
      self.train.V.data[itemId]:append(torch.Tensor{userId,rating})

      --update the training mean
      self.__n    =  self.__n + 1
      self.__mean = (self.__n*self.__mean + rating) / ( self.__n + 1 )

   else
      if self.test.U.data[userId] == nil then self.test.U.data[userId] = nnsparse.DynamicSparseTensor.new(200) end
      if self.test.V.data[itemId] == nil then self.test.V.data[itemId] = nnsparse.DynamicSparseTensor.new(200) end 

      self.test.U.data[userId]:append(torch.Tensor{itemId,rating})
      self.test.V.data[itemId]:append(torch.Tensor{userId,rating})
   end
   
end


--private method
function DataLoader:__reset() 
   self.train = {U = { data = {}, info = {} }, V = { data = {}, info = {}}}
   self.test  = {U = { data = {}, info = {} }, V = { data = {}, info = {}}}
   
   self.__Usize = 0
   self.__Vsize = 0
   self.__mean  = 0
   self.__n     = 0
   
   self.__noRating = 0
end


function DataLoader:__PostProcessRating()

   -- sort sparse vectors (This is required to make nn.SparseLinear works)
   local function build(X) 
      for k, x in pairs(X.data) do 
         X.data[k] = torch.Tensor.ssortByIndex(x:build())
      end 
   end
   
   build(self.train.U)
   build(self.train.V)
   build(self.test.U)
   build(self.test.V)


   --store mean, globalMean and std for every row/column
   local function computeBias(X,gMean)
      for k, x in pairs(X.data) do
         X.info[k] = X.info[k] or {}
         X.info[k].mean  = x[{{},2}]:mean()
         X.info[k].std   = x[{{},2}]:std()
         X.info[k].gMean = gMean
      end
   end
   
   computeBias(self.train.U, self.__mean)
   computeBias(self.train.V, self.__mean)

   --Provide external information
   self.train.U.size, self.test.U.size = self.__Usize, self.__Usize
   self.train.V.size, self.test.V.size = self.__Vsize, self.__Vsize

   self.train.U.dimension, self.test.U.dimension = self.__Vsize, self.__Vsize
   self.train.V.dimension, self.test.V.dimension = self.__Usize, self.__Usize
   
   self.train.U.noRating, self.test.U.noRating = self.__n, self.__noRating - self.__n
   self.train.V.noRating, self.test.V.noRating = self.__n, self.__noRating - self.__n
   
   print(self.__Usize .. " users were loaded.")
   print(self.__Vsize .. " items were loaded.")

end


----------------------------------------------------------------------------
----------------------------------------------------------------------------

local doubanLoader, parent = torch.class('doubanLoader', 'DataLoader')

function doubanLoader:LoadRatings(conf)

   --no pre-process/post-processing
   function preprocess(x)  return (x-3)/2 end
   function postprocess(x) return 2*x+3 end

   -- step 3 : load ratings
   local ratesfile = io.open(conf.ratings, "r")

   self.movieHash = {}
   self.userHash  = {}

   local itemCounter = 1
   local userCounter = 1
 
   -- Step 1 : Retrieve movies'scores...th
   local i = 0
   for line in ratesfile:lines() do

      local userIdStr, movieIdStr, ratingStr = line:match('(%d+) (%d+) (%d+)')

      local userId  = tonumber(userIdStr)
      local itemId  = tonumber(movieIdStr)
      local rating  = tonumber(ratingStr)

      local itemIndex = self.movieHash[itemId]
      if itemIndex == nil then
         self.movieHash[itemId] = itemCounter
         itemIndex   = itemCounter
         itemCounter = itemCounter + 1
      end

      local userIndex = self.userHash[userId]
      if userIndex == nil then
         self.userHash[userId] = userCounter
         userIndex   = userCounter
         userCounter = userCounter + 1
      end


      rating = preprocess(rating)

      self:AppendOneRating(userIndex, itemIndex, rating)

      i = i + 1
      
      if math.fmod(i, 100000) == 0 then
         print(i .. " ratings loaded...")
      end

   end
   ratesfile:close()

end


function doubanLoader:LoadMetaU(conf) 

  if #conf.metaUser > 0 then

    local csv2tensor = require 'csv2tensor'
    local friendTensor  = csv2tensor.load(conf.metaUser)

    for i = 1, friendTensor:size(1) do

      -- idUser, friends1, friends2, friends3 etc.
      local userId  = friendTensor[i][1]
      local friends = friendTensor[{i, {2, friendTensor:size(2)}}]

      local userIndex = self.userHash[userId]
      if userIndex ~= nil then
        local info = self.train.U.info[userIndex] or {}
        
        info.friends    = friends

        info.full       = friends
        info.fullSparse = friends:sparsify(0, self.train.U.dimension)

        self.train.U.info[userIndex] = info
      end

    end
    self.train.U.info.metaDim = self.train.U.info[1].full:size(1)
  end
end


<<<<<<< HEAD
=======


>>>>>>> cd903f1b5bfc1c099a7d030245316daa978f0903
----------------------------------------------------------------------------
----------------------------------------------------------------------------

local jesterLoader, parent = torch.class('jesterLoader', 'DataLoader')

function jesterLoader:LoadRatings(conf)

   function preprocess(x)  return (x)/10 end
   function postprocess(x) return (x)*10 end

   local file = torch.DiskFile(conf.ratings, "r")
   local data = file:readObject()

   -- Step 1 : Retrieve rating by jokes
   for i = 1, data:size(1) do
      for j = 1, data:size(2) do

         local t = data[i][j]

         if t ~= 99 then

            local userId = i
            local itemId = j
            local rating =  preprocess(t)
   
            self:AppendOneRating(userId, itemId, rating)
         end 
      end
   end

end


----------------------------------------------------------------------------
----------------------------------------------------------------------------

local dummyLoader, parent = torch.class('dummyLoader', 'DataLoader')

function dummyLoader:__init(noUsers, noItems, sparseRate)
   self.sparseRate = 0.4
   self.noUsers = 200
   self.noItems = 200
   self.sparsifier = function(x) if torch.uniform() < self.sparseRate then return 0 else return x end end
end

function dummyLoader:LoadRatings(conf)

   function preprocess(x)  return x end
   function postprocess(x) return x end

   local data = torch.Tensor(self.noUsers, self.noItems):uniform(-1, 1)
   data:apply(self.sparsifier)
  
   for i = 1, data:size(1) do
      for j = 1, data:size(2) do

         local t = data[i][j]

         if t ~= 0 then
   
            local userId = i
            local itemId = j
            local rating = preprocess(t)
   
            self:AppendOneRating(userId, itemId, rating)
         end 
      end
   end

end
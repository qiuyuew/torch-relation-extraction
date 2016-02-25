--
-- User: pat
-- Date: 9/1/15
--


package.path = package.path .. ";src/?.lua"

require 'CmdArgs'
require 'EncoderFactory'
require 'rnn'
require 'UniversalSchemaEncoder'
require 'UniversalSchemaRelationPooling'
require 'UniversalSchemaEntityEncoder'
require 'UniversalSchemaJointEncoder'
require 'TransEEncoder'
require 'PositiveOnlyUniversalSchema'


local SparseClassifier, parent = torch.class('SparseClassifier', 'UniversalSchemaEncoder')

local kb_rels = {}
local kb_file = 'data/revised-split/torch/vocabs/kb-indices.txt'
io.write('Loading kb map... ')
local new_id = 1
for line in io.lines(kb_file) do
    local token, id = string.match(line, "([^\t]+)\t([^\t]+)")
    if token and id then
        id = tonumber(id)
        if id > 1 then kb_rels[id] = new_id; new_id = new_id + 1 end
    end
end
print('Done')

function SparseClassifier:__init(params, row_table, row_encoder, col_table, col_encoder, use_entities)
    self.__index = self
    self.params = params
    self.opt_config = { learningRate = self.params.learningRate, epsilon = self.params.epsilon,
        beta1 = self.params.beta1, beta2 = self.params.beta2,
        momentum = self.params.momentum, learningRateDecay = self.params.decay
    }
    self.opt_state = {}
    self.train_data = self:load_train_data(params.train, use_entities)


    -- either load model from file or initialize new one
    if params.loadModel ~= '' then
        local loaded_model = torch.load(params.loadModel)
        self.net = self:to_cuda(loaded_model.net)
        self.opt_state = loaded_model.opt_state
        for key, val in pairs(loaded_model.opt_state) do
            if (torch.type(val) == 'torch.DoubleTensor') then self.opt_state[key] = self:to_cuda(val) end
        end
    else
        self.net = self:build_network()
    end

    -- set the criterion
    self.crit = nn.ClassNLLCriterion()
    self:to_cuda(self.crit)
end



function SparseClassifier:build_network()
    local net = nn.Sequential()
        :add(nn.SparseLinear(self.train_data.num_cols, 41))
        :add(nn.LogSoftMax())
    -- put the networks on cuda
    self:to_cuda(net)
    return net
end


function SparseClassifier:gen_subdata_batches_three_col(data, sub_data, batches, max_neg, shuffle)
    local start = 1
    local kb_indices = {}
    local kb_mapped = {}
    -- only keep kb exampels
    for i = 1, sub_data.row:size(1) do
        if kb_rels[sub_data.row[i]] then
           table.insert(kb_mapped,  kb_rels[sub_data.row[i]])
           table.insert(kb_indices,  i)
        end
        i = i + 1
    end
    if #kb_indices > 0 then
        sub_data.row = torch.Tensor(kb_mapped)
        local index = torch.LongTensor(kb_indices)
        sub_data.col = sub_data.col:index(1, index)
        local rand_order = shuffle and torch.randperm(sub_data.row:size(1)):long() or torch.range(1, sub_data.row:size(1)):long()
        while start <= sub_data.row:size(1) do
            local size = math.min(self.params.batchSize, sub_data.row:size(1) - start + 1)
            local batch_indices = rand_order:narrow(1, start, size)
            local row_batch = sub_data.row:index(1,batch_indices)
            local col_batch = sub_data.col:index(1,batch_indices)
            col_batch = col_batch:view(col_batch:size(2), 1)
            col_batch = col_batch:cat(torch.ones(col_batch:size(1)))
            table.insert(batches, { data = col_batch, label = row_batch })
            start = start + size
        end
    end
end


function SparseClassifier:score_subdata(sub_data)
    local batches = {}
    self:gen_subdata_batches_three_col(sub_data, sub_data, batches, 0, false)

    local scores = {}
    for i = 1, #batches do
        local score = self.net(batches[i].data)[batches[i].label[1]]
        table.insert(scores, score)
    end
    return scores, sub_data.label:view(sub_data.label:size(1))
end

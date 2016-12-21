local classic = require 'classic'
local optim = require 'optim'
require 'optimiser/sharedRmsProp'
local Plot = require 'itorch.Plot'
local tnt = require 'torchnet'

local Master = classic.class('Master')

local load_closure = function(thread_idx, partition, epoch_size, fm_init, fm_generator, fm_postprocess, bundle, opt)
    local tnt = require 'torchnet'
    local rl = require 'train.rl_framework.infra.env'
    -- It is by default a batchdataset.
    return rl.Dataset{
        forward_model_init = fm_init,
        forward_model_generator = fm_generator,
        forward_model_batch_postprocess = fm_postprocess,
        batchsize = opt.batchsize,
        thread_idx = thread_idx,
        partition = partition,
        bundle = bundle,
        epoch_size = epoch_size,
        opt = opt
    }
end

local function build_dataset(thread_init, fm_init, fm_gen, fm_postprocess, bundle, partition, epoch_size, opt)
    local dataset
    if opt.nthread > 0 then
        dataset = tnt.ParallelDatasetIterator{
            nthread = opt.nthread,
            init = function()
                require 'cutorch'
                require 'torchnet'
                require 'cudnn'
                if opt.gpu and opt.nGPU == 1 then
                    cutorch.setDevice(opt.gpu)
                end
                if thread_init ~= nil then thread_init() end
            end,
            closure = function(thread_idx)
                return load_closure(thread_idx, partition, epoch_size, fm_init, fm_gen, fm_postprocess, bundle, opt)
            end
        }
    else
        dataset = tnt.DatasetIterator{
            dataset = load_closure(1, partition, epoch_size, fm_init, fm_gen, fm_postprocess, bundle, opt)
        }
    end
    return dataset
end

function Master:_init(opt,net,crit,callbacks)
	-- body
	self.opt = opt
	self.net = net
	self.crit = crit
  	self.theta, self.dTheta = self.net:getParameters()	
  	self.dTheta:zero()
  	self.maxepoch = opt.maxepoch
  	self.optimiser = optim[opt.optimiser]
  	local sharedG = self.theta:clone():zero()
  	self.optimParams = {
  		learningRate = opt.learningRate,
  		momentum = opt.momentum,
      	rmsEpsilon = opt.rmsEpsilon,	
      	g = sharedG
  	}
    local thread_init = callbacks.thread_init
    local fm_init = callbacks.forward_model_init
    local fm_gen = callbacks.forward_model_generator
    local fm_postprocess = callbacks.forward_model_batch_postprocess
   	self.train_dataset = build_dataset(thread_init, fm_init, fm_gen, fm_postprocess, bundle, "train", opt.epoch_size, opt)
    self.test_dataset = build_dataset(thread_init, fm_init, fm_gen, fm_postprocess, bundle, "test", opt.epoch_size_test, opt)
end

function Master:applyGradients()

  local feval = function()
    -- loss needed for validation stats only which is not computed for async yet, so just 0
    local loss = 0 -- 0.5 * tdErr ^2
    return loss, self.dTheta
  end

  --self.optimParams.learningRate = self.learningRateStart * (self.totalSteps - self.step) / self.totalSteps
  self.optimiser(feval, self.theta, self.optimParams)

  self.dTheta:zero()
end

function Master:train()

	local epoch = 0
	local acc_errs = 0
	local t = 0
	local net = self.net
	local crit = self.crit
	while epoch < self.maxepoch do
	    net:training()
	    acc_errs = 0
	    t = 0

	    for sample in self.iterator() do
	    -- for i = 1, 100 do
	    -- 	sample = {
	    -- 		s = torch.ones(4,25,19,19):cuda(),
	    -- 		a = torch.ones(4,3):cuda()

	    -- 	}

			-- This includes forward/backward and parameter update.
			-- Different RL will use different approaches.
			net:forward(sample.s)
			local errs = crit:forward(net.output,sample.a)
			local grad = crit:backward(net.output,sample.a)

			net:backward(sample.s,grad)

	        acc_errs = acc_errs + errs

	        t = t + 1

	        self:applyGradients()

	        print(errs)
	    end

	    -- Update the sampling model.
	    -- state.agent:update_sampling_model(update_sampling_before)
	    state.agent:update_sampling_model()

	    state.epoch = state.epoch + 1

	end

end

function Master:test(opt)
	local a
end


return Master
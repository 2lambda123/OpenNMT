require 's2sa.dict'
local path = require 'pl.path'

local models = require 's2sa.models'
local model_utils = require 's2sa.model_utils'
local table_utils = require 's2sa.table_utils'

local Bookkeeper = require 's2sa.bookkeeper'
local Data = require 's2sa.data'
local Decoder = require 's2sa.decoder'
local Encoder = require 's2sa.encoder'
local Evaluator = require 's2sa.evaluator'
local Learning = require 's2sa.learning'

local cmd = torch.CmdLine()
local opt = {}
local layers = {}
local word_vecs_enc = {}
local word_vecs_dec = {}
local encoder
local decoder
local attention
local generator
local criterion

cmd:text("")
cmd:text("**Data options**")
cmd:text("")
cmd:option('-data','data/demo.t7', [[Path to the training *.hdf5 file from preprocess.py]])
cmd:option('-savefile', 'seq2seq_lstm_attn', [[Savefile name (model will be saved as
                                             savefile_epochX_PPL.t7 where X is the X-th epoch and PPL is
                                             the validation perplexity]])
cmd:option('-train_from', '', [[If training from a checkpoint then this is the path to the pretrained model.]])

cmd:text("")
cmd:text("**Model options**")
cmd:text("")

cmd:option('-num_layers', 2, [[Number of layers in the LSTM encoder/decoder]])
cmd:option('-rnn_size', 500, [[Size of LSTM hidden states]])
cmd:option('-word_vec_size', 500, [[Word embedding sizes]])

cmd:text("")
cmd:text("**Optimization options**")
cmd:text("")

cmd:option('-max_batch_size', 64, [[Maximum batch size]])
cmd:option('-epochs', 13, [[Number of training epochs]])
cmd:option('-start_epoch', 1, [[If loading from a checkpoint, the epoch from which to start]])
cmd:option('-param_init', 0.1, [[Parameters are initialized over uniform distribution with support (-param_init, param_init)]])
cmd:option('-learning_rate', 1, [[Starting learning rate. If adagrad/adadelta/adam is used,
                                then this is the global learning rate. Recommended settings: sgd =1,
                                adagrad = 0.1, adadelta = 1, adam = 0.1]])
cmd:option('-max_grad_norm', 5, [[If the norm of the gradient vector exceeds this renormalize it to have the norm equal to max_grad_norm]])
cmd:option('-dropout', 0.3, [[Dropout probability. Dropout is applied between vertical LSTM stacks.]])
cmd:option('-lr_decay', 0.5, [[Decay learning rate by this much if (i) perplexity does not decrease
                             on the validation set or (ii) epoch has gone past the start_decay_at_limit]])
cmd:option('-start_decay_at', 9, [[Start decay after this epoch]])
cmd:option('-pre_word_vecs_enc', '', [[If a valid path is specified, then this will load
                                     pretrained word embeddings (hdf5 file) on the encoder side.
                                     See README for specific formatting instructions.]])
cmd:option('-pre_word_vecs_dec', '', [[If a valid path is specified, then this will load
                                     pretrained word embeddings (hdf5 file) on the decoder side.
                                     See README for specific formatting instructions.]])
cmd:option('-fix_word_vecs_enc', 0, [[If = 1, fix word embeddings on the encoder side]])
cmd:option('-fix_word_vecs_dec', 0, [[If = 1, fix word embeddings on the decoder side]])

cmd:text("")
cmd:text("**Other options**")
cmd:text("")

-- GPU
cmd:option('-gpuid', -1, [[Which gpu to use. < 1 = use CPU]])

-- bookkeeping
cmd:option('-save_every', 1, [[Save every this many epochs]])
cmd:option('-print_every', 50, [[Print stats after this many batches]])
cmd:option('-seed', 3435, [[Seed for random initialization]])


local function save_model(model_path, data, options, double)
  print('saving model to ' .. model_path)
  if double then
    for i = 1, #data do data[i] = data[i]:double() end
  end
  torch.save(model_path, {data, options})
end

local function train(train_data, valid_data)
  local num_params = 0
  local num_prunedparams = 0
  local params, grad_params = {}, {}
  local max_length = math.max(opt.max_source_length, opt.max_target_length)
  opt.train_perf = {}

  local encoderMngt = Encoder.new({
    network = encoder,
    word_vecs_enc = word_vecs_enc,
    pre_word_vecs_enc = opt.pre_word_vecs_enc,
    fix_word_vecs_enc = opt.fix_word_vecs_enc,
  })
  local decoderMngt = Decoder.new({
    network = decoder,
    word_vecs_dec = word_vecs_dec,
    pre_word_vecs_dec = opt.pre_word_vecs_dec,
    fix_word_vecs_dec = opt.fix_word_vecs_dec,
  })

  for i = 1, #layers do
    local p, gp = layers[i]:getParameters()
    if opt.train_from:len() == 0 then
      p:uniform(-opt.param_init, opt.param_init)
    end
    num_params = num_params + p:size(1)
    params[i] = p
    grad_params[i] = gp
  end

  print("Number of parameters: " .. num_params .. " (active: " .. num_params-num_prunedparams .. ")")

  local h_init = torch.zeros(opt.max_batch_size, opt.rnn_size)
  if opt.gpuid > 0 then
    h_init = h_init:cuda()
  end

  local init_states_fwd = {}
  local init_states_bwd = {}

  for _ = 1, opt.num_layers do
    table.insert(init_states_fwd, h_init:clone())
    table.insert(init_states_bwd, h_init:clone())
  end

  function train_batch(data, epoch, learning)
    local bookkeeper = Bookkeeper.new({
      print_frequency = opt.print_every,
      learning_rate = learning:get_rate(),
      data_size = #data,
      epoch = epoch
    })

    local batch_order = torch.randperm(#data) -- shuffle mini batch order

    for i = 1, #data do
      table_utils.zero(grad_params, 'zero')

      local batch = data:get_batch(batch_order[i])

      local hidden_states = model_utils.reset_state(init_states_fwd, batch.size)

      -- forward encoder
      local encoder_inputs = hidden_states
      table.insert(encoder_inputs, batch.source_input)
      local encoder_states, context = encoderMngt:forward(encoder_inputs)

      -- forward decoder
      local decoder_inputs = encoder_states
      table.insert(decoder_inputs, batch.target_input)
      local decoder_out = decoderMngt:forward(decoder_inputs)

      -- forward and backward attention and generator
      local grad_context = context:clone():zero()
      local decoder_grad_output = model_utils.reset_state(init_states_bwd, batch.size)
      table.insert(decoder_grad_output, decoder_out:clone())

      local loss = 0

      for t = 1, batch.target_length do
        local out = decoder_out:select(2, t)

        local attention_output = attention:forward({out, context})
        local generator_output = generator:forward(out)

        loss = loss + criterion:forward(generator_output, batch.target_output[{{}, t}]) / batch.size
        local criterion_grad_input = criterion:backward(generator_output, batch.target_output[{{}, t}]) / batch.size

        local generator_grad_input = generator:backward(out, criterion_grad_input)
        local attn_grad_input = attention:backward({out, context}, generator_grad_input)

        decoder_grad_output[#decoder_grad_output][{{}, t}]:copy(attn_grad_input[1])
        grad_context:add(attn_grad_input[2]) -- accumulate gradient of context
      end

      -- backward decoder
      local decoder_grad_input = decoderMngt:backward(decoder_inputs, decoder_grad_output)

      local grad_norm = grad_params[2]:norm()^2 + grad_params[3]:norm()^2

      -- backward encoder
      local encoder_grad_output = decoder_grad_input
      encoder_grad_output[#encoder_grad_output] = grad_context
      encoderMngt:backward(encoder_inputs, encoder_grad_output)

      grad_norm = grad_norm + grad_params[1]:norm()^2
      grad_norm = grad_norm^0.5

      -- Shrink norm and update params
      local param_norm = 0
      local shrinkage = opt.max_grad_norm / grad_norm
      for j = 1, #grad_params do
        if shrinkage < 1 then
          grad_params[j]:mul(shrinkage)
        end
        params[j]:add(grad_params[j]:mul(-learning:get_rate()))
        param_norm = param_norm + params[j]:norm()^2
      end
      param_norm = param_norm^0.5

      -- Bookkeeping
      bookkeeper:update({
        source_size = batch.source_length,
        target_size = batch.target_length,
        batch_size = batch.size,
        batch_index = i,
        nonzeros = batch.target_non_zeros,
        loss = loss,
        param_norm = param_norm,
        grad_norm = grad_norm
      })

      if i % 200 == 0 then
        collectgarbage()
      end
    end

    return bookkeeper:get_train_score()
  end

  local evaluator = Evaluator.new(opt.num_layers)
  local learning = Learning.new(opt.learning_rate, opt.lr_decay, opt.start_decay_at)

  for epoch = opt.start_epoch, opt.epochs do
    encoder:training()
    decoder:training()
    attention:training()
    generator:training()

    local train_score = train_batch(train_data, epoch, learning)

    print('Train', train_score)
    opt.train_perf[#opt.train_perf + 1] = train_score

    local score = evaluator:process({
      encoder = encoderMngt,
      decoder = decoderMngt,
      attention = attention,
      generator = generator,
      init_fwd_enc = encoderMngt.init_fwd_enc,
      init_fwd_dec = decoderMngt.init_fwd_dec,
      context_proto = context_proto,
      criterion = criterion
    }, valid_data)
    learning:update_rate(score, epoch)

    -- clean and save models
    if epoch % opt.save_every == 0 then
      save_model(string.format('%s_epoch%.2f_%.2f.t7', opt.savefile, epoch, score), {encoder, decoder, generator}, opt, false)
    end
  end
  -- save final model
  save_model(string.format('%s_final.t7', opt.savefile), {encoder, decoder, generator}, opt, true)
end

local function get_layer(layer)
  if layer.name ~= nil then
    if layer.name == 'word_vecs_dec' then
      word_vecs_dec = layer
    elseif layer.name == 'word_vecs_enc' then
       word_vecs_enc = layer
    end
  end
end

local function main()
  -- parse input params
  opt = cmd:parse(arg)

  torch.manualSeed(opt.seed)

  local cuda = opt.gpuid > 0
  if cuda then
    print('using CUDA on GPU ' .. opt.gpuid .. '...')
    require 'cutorch'
    require 'cunn'
    cutorch.setDevice(opt.gpuid)
    cutorch.manualSeed(opt.seed)
  end

  -- Create the data loader class.
  print('Loading data from ' .. opt.data .. '...')
  local dataset = torch.load(opt.data)
  local train_data = Data.new(dataset.train, opt.max_batch_size, cuda)
  local valid_data = Data.new(dataset.valid, opt.max_batch_size, cuda)
  print('... done')

  opt.max_source_length = math.max(train_data.max_source_length, valid_data.max_source_length)
  opt.max_target_length = math.max(train_data.max_target_length, valid_data.max_target_length)

  print(string.format('Source vocab size: %d, Target vocab size: %d', #dataset.src_dict, #dataset.targ_dict))
  print(string.format('Source max sent len: %d, Target max sent len: %d',
                      opt.max_source_length, opt.max_target_length))

  -- Build model
  if opt.train_from:len() == 0 then
    encoder = models.make_lstm(#dataset.src_dict, opt, 'enc')
    decoder = models.make_lstm(#dataset.targ_dict, opt, 'dec')
    attention = models.make_attention(opt)
    criterion, generator = models.make_generator(#dataset.targ_dict, opt)
  else
    assert(path.exists(opt.train_from), 'checkpoint path invalid')
    print('loading ' .. opt.train_from .. '...')
    local checkpoint = torch.load(opt.train_from)
    local model, model_opt = checkpoint[1], checkpoint[2]
    opt.num_layers = model_opt.num_layers
    opt.rnn_size = model_opt.rnn_size
    encoder = model[1]
    decoder = model[2]
    generator = model[3]
    criterion = models.make_generator(valid_data, opt)
  end

  layers = {encoder, decoder, generator}

  if cuda then
    for i = 1, #layers do
      layers[i]:cuda()
    end
    criterion:cuda()
    attention:cuda()
  end

  -- these layers will be manipulated during training
  encoder:apply(get_layer)
  decoder:apply(get_layer)
  train(train_data, valid_data)
end

main()

-- A convolution layer with a gated activation unit as described in the Conditional PixelCNN paper.
-- This convolution layer includes a vertical/horizontal stack, and is intended for use in image generation.

require('torch')
require('nn')
require('nngraph')

-- local GatedPixelConvolution = torch.class('GatedPixelConvolution')
pixelCNN = {}

function pixelCNN.toImage(output)
	-- Expects raw output from the network, which is 
	-- each table index is a channel of the output image.
	local dim = output[1]:dim()
	local size = output[1]:size()
	local batched = false
	local image
	local width
	local height
	local classes
	-- print(size)

	if dim > 4 then
		error("output channels must have at most 4 dimensions (batch x classes x N x M)")
	elseif dim < 3 then
		error("output channels must have at least 3 dimensions (classes x N x M)")
	end

	if dim == 4 then batched = true end

	if batched then
		classes = size[2]
		width = size[3]
		height = size[4]
		image = torch.Tensor(size[1], 3, width, height)
		image:fill(1)
	else
		classes = size[1]
		width = size[2]
		height = size[3]
		image = torch.Tensor(3, width, height)
		image:fill(1)
	end

	local function getValues(channel)
		local size = channel:size()
		local values = torch.Tensor(width, height)
		-- print(values:size())
		for x=1,width do
			for y=1,height do
				local value, _
				_,value = channel[{{},x,y}]:max(1)
				values[{x,y}] = value[1]/classes
			end
		end

		return values
	end

	for idx,channel in pairs(output) do
		if not channel:isSize(size) then
			error("all output channels must have the same size")
		end

		if batched then
			for batchIdx = 1,size[1] do
				-- print(image[{batchIdx,idx,{},{}}]:size())
				image[{batchIdx,idx,{},{}}] = getValues(channel[batchIdx])
			end
		else
			image[channel] = getValues(channel)
		end
	end

	-- if #output < 3 then
	-- 	for idx=#output+1,3 do
	-- 		image[idx]

	return image
end

function pixelCNN.GAU(planes, left, right)
	left_type = left or nn.Tanh
	right_type = right or nn.Sigmoid

	local input = - nn.Identity()

	local left = input 
		- nn.Narrow(-3, 1, planes/2)
		- left_type()

	local right = input
		- nn.Narrow(-3, planes/2, planes/2)
		- right_type()

	local gate = nn.CMulTable()({left,right})

	return nn.gModule({input}, {gate})
end

function pixelCNN.MultiChannelSpatialSoftMax(channels)
	if channels == 1 then
		-- Easy degenerate case.
		return nn.SpatialSoftMax()
	end
end

function pixelCNN.inputLayer(nOutputPlane, kernel_size, kernel_step, channels)
	channels = channels or 3
	local input = nn.Replicate(2)():annotate{
		name = 'rep', description = 'replicate input (x2)'
	}

	local layer = input 
		- nn.SplitTable(1)
		- pixelCNN.GatedPixelConvolution(1, nOutputPlane, kernel_size, kernel_step, 1, channels, false)
	layer:annotate{name = 'input layer', description = 'massage input, first pixel convolution layer'}

	return nn.gModule({input}, {layer})
end

function pixelCNN.outputLayer(nInputPlane, channels)
	channels = channels or 3

	local input = nn.SelectTable(2)():annotate{
		description = 'select horiz stack output'
	}
	local outputs = {}

	for channel=1,channels do
		local start = (channel - 1)*nInputPlane + 1
		outputs[channel] = nn.Narrow(-3, start, nInputPlane)(input):annotate{
			name = 'out_ch' .. channel,
			description = 'split output for channel ' .. channel
		}
	end

	return nn.gModule({input}, outputs)
end

function pixelCNN.GatedPixelConvolution(nInputPlane, nOutputPlane, kernel_size, kernel_step, layer, channels, force_residual)
	-- nInputPlane and nOutputPlane are per-channel. This will multiply accordingly.

	force_residual = force_residual or true
	layer = layer or 3
	channels = channels or 3

	local channel_colors = {
		'red',
		'green',
		'blue'
	}

	-- If we're at the first layer, we can't look at the current pixel.
	-- If we're at a later layer, we can.
	-- If we're at the second layer, a channel doesn't look at itself as an input.
	-- If we're at a later layer, it does.

	-- In each layer, there is one full convolutional unit per channel. The layer takes in
	-- N x M x channels x nInputPlane features.
	-- Beyond the 2nd layer, each channel takes every channel up to and including itself as
	-- and input, and each channel produces an N x M x nOutputPlane output.
	-- At the second layer, this is the same except each channel does not take its corresponding input.
	-- At the first layer, the input is N x M x channels in size.

	-- Can I do this simply by masking convolutions?
	-- for a 3 channel input:
	-- the first third of the kernels masks out all but the first channel
	-- the second third masks out the third channel
	-- the final third masks nothing out

	-- It may be simpler to just have 3 parallel convolutional stacks, and concatenate their
	-- outputs. I -think- that's entirely equivalent, though that depends on what the gated
	-- unit does (well, it has no weights)
	-- That is, where there are currently single convolutions, I can maybe place concat layers to handle it
	-- Or, I just put 3 of these in parallel with the appropriate # of planes, then narrow and concat as appropriate.

	-- If nInputPlane and nOutputPlane are the same, force residuals.
	if nInputPlane == nOutputPlane then force_residual = true end

	-- TODO: implement dilated convolutions a la wavenet

	-- Vertical stack can only depend on pixels above the current pixel. This can be achieved by 
	-- using a filter of half height, and padding the input appropriately.

	local hstack_in = {}
	local hstack_out = {}
	local vstack_in = {}
	local vstack_out = {}
	local hstack_in_all = - nn.Identity()
	local hstack_out_all
	local vstack_in_all = - nn.Identity()
	local vstack_out_all

	for channel=1,channels do
		local vertical_conv, vertical_pad
		do
			local kW = kernel_size
			local kH = math.floor(kernel_size/2) -- Paper says ceil. I don't believe it.
			local dW = kernel_step
			local dH = kernel_step
			local padW = 0
			local padH = 0

			vertical_pad = nn.SpatialZeroPadding(
				math.floor(kernel_size/2), 
				math.floor(kernel_size/2),
				math.floor(kernel_size/2),
				0)
			vertical_conv = nn.SpatialConvolution(nInputPlane*channel, 2*nOutputPlane, kW, kH, dW, dH, padW, padH)
			local params,_ = vertical_conv:getParameters()

			-- We'll have 1 extra pixel on the bottom of the image. Get rid of it.
			vertical_crop = nn.SpatialZeroPadding(0, 0, 0, -1)
		end

		local horiz_conv, horiz_pad
		do
			local kH = 1
			local dW = kernel_step
			local dH = kernel_step
			local padW = 0
			local padH = 0

			local kW
			if layer == 1 then
				kW = math.floor(kernel_size/2) -- Don't include the current pixel
			else
				kW = math.ceil(kernel_size/2) -- Include the current pixel
			end

			horiz_pad = nn.SpatialZeroPadding(math.floor(kernel_size/2), 0, 0, 0)
			-- nn.Padding(3, -math.floor(kernel_size/2), 3)
			horiz_conv = nn.SpatialConvolution(nInputPlane*channel, 2*nOutputPlane, kW, kH, dW, dH, padW, padH)
			local params,_ = horiz_conv:getParameters()
			-- print("horizontal convolution has " .. params:storage():size() .. " hidden units")

			if layer == 1 then
				-- Sizes mean we'll still have 1 extra pixel on the right side of the image. Get rid of it.
				horiz_crop = nn.SpatialZeroPadding(0, -1, 0, 0)
			else
				horiz_crop = nn.Identity()
			end
		end

		-- Input to the layer is {tensor, tensor}. The first tensor goes to the vertical stack; the second to the
		-- horizontal stack.

		-- We need to select the features from the input corresponding to this channel and all before it.
		-- We assume that the number of input planes (like the # of output planes we generate) is per-channel,
		-- so for each channel we need to grab that many and all of the ones leading up to it.

		local graphAttributes = {
			color = channel_colors[channel]
		}

		vstack_in[channel] = nn.Narrow(-3, 1, channel*nInputPlane)(vstack_in_all):annotate{
			name = 'vnarrow_ch' .. channel, 
			description = 'narrow vertical input to channels 1-' .. channel,
			graphAttributes = graphAttributes
		}

		local vconv_out = vertical_pad(vstack_in[channel]):annotate{
			name = 'vpad_ch' .. channel, 
			description = 'padding for vertical convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		vconv_out = vertical_conv(vconv_out):annotate{
			name = 'vconv_ch' .. channel, 
			description = vertical_conv.kW .. 'x' .. vertical_conv.kH .. ' vertical convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		vconv_out = vertical_crop(vconv_out):annotate{
			name = 'vcrop_ch' .. channel,
			description = 'crop for vertical convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		vstack_out[channel] = pixelCNN.GAU(2*nOutputPlane)(vconv_out):annotate{
			name = 'vgate_ch' .. channel,
			description = 'gated output for vertical stack (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}  -- Output is gated vertical convolution


		hstack_in[channel] = nn.Narrow(-3, 1, channel*nInputPlane)(hstack_in_all):annotate{
			name = 'hnarrow_ch' .. channel, 
			description = 'narrow horiz input to channels 1-' .. channel,
			graphAttributes = graphAttributes
		}

		local hconv_out = horiz_pad(hstack_in[channel]):annotate{
			name = 'hpad_ch' .. channel, 
			description = 'padding for horiz convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		hconv_out = horiz_conv(hconv_out):annotate{
			name = 'hconv_ch' .. channel, 
			description = horiz_conv.kW .. 'x' .. horiz_conv.kH .. ' horiz convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		hconv_out = horiz_crop(hconv_out):annotate{
			name = 'hcrop_ch' .. channel,
			description = 'crop for horiz convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		} -- Output is 1xn horizontal convolution



		local vtohconv = nn.SpatialConvolution(2*nOutputPlane, 2*nOutputPlane, 1, 1, 1, 1)
		local vconv_to_hconv = vtohconv(vconv_out):annotate{
			name = 'vtohconv_ch' .. channel,
			description = vtohconv.kW .. 'x' .. vtohconv.kH .. ' vertical conv -> horiz stack conv (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}


		local hstack = nn.CAddTable()({hconv_out, vconv_to_hconv}):annotate{
			name = 'vhadd_ch' .. channel,
			description = 'add vertical convolution to horiz convolution (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		hstack = pixelCNN.GAU(2*nOutputPlane)(hstack):annotate{
			name = 'hgate_ch' .. channel,
			description = 'gated output for horiz stack (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		local hstack_outconv = nn.SpatialConvolution(nOutputPlane, nOutputPlane, 1, 1, 1, 1)
		hstack = hstack_outconv(hstack):annotate{
			name = 'hstackconv_ch' .. channel,
			description = hstack_outconv.kW .. 'x' .. hstack_outconv.kH .. ' horiz stack output conv (ch' .. channel .. ')',
			graphAttributes = graphAttributes
		}

		-- hstack output is gated elementwise addition of vconv output (convolved w/ 1x1 filter) and hconv output

		-- Add residual on horizontal stack
		
		if force_residual then
			if channel*nInputPlane == nOutputPlane then
				-- If input and output dimensions are the same, we can just use the identity.
				hstack_out[channel] = nn.CAddTable()({hstack_in[channel], hstack}):annotate{
					name = 'hstack_residual_ch' .. channel,
					description = 'horiz stack residual (ch' .. channel .. ')',
					graphAttributes = graphAttributes
				}
			else
				-- Otherwise, use a 1x1 convolution to transform dimensions.
				local residual_conv = nn.SpatialConvolution(nInputPlane*channel, nOutputPlane, 1, 1, 1, 1)

				local transform = residual_conv(hstack_in[channel]):annotate{
					name = 'hstack_residualconv_ch' .. channel,
					description = residual_conv.kW .. 'x' .. residual_conv.kH .. ' horiz stack residual transform (ch' .. channel .. ')',
					graphAttributes = graphAttributes
				}
				hstack_out[channel] = nn.CAddTable()({transform, hstack}):annotate{
					name = 'hstack_residual_ch' .. channel,
					description = 'horiz stack residual (ch' .. channel .. ')',
					graphAttributes = graphAttributes
				}
			end
		else
			-- hstack output is directly from the stack. no residual.
			hstack_out[channel] = hstack
		end

		nngraph.annotateNodes()

	end

	-- Now we have the hstack and vstack inputs and outputs for each channel. Piece them together.
	hstack_out_all = nn.JoinTable(1,3)(hstack_out)
	vstack_out_all = nn.JoinTable(1,3)(vstack_out)

	return nn.gModule({vstack_in_all, hstack_in_all}, {vstack_out_all, hstack_out_all})
end

local Helper = torch.class('pixelCNN.Helper')

function Helper:__init(opts)
	opts = opts or {}
	self.channels = opts.channels or 3
	self.force_residual = opts.force_residual or true
	self.sample_input = opts.input or torch.Tensor(3,32,32)
	self.layers = {}
end

function Helper:addLayer(nOutputPlane, kernel_size)
	if #self.layers == 0 then
		-- Create the input layer
		self.layers[#self.layers+1] = {
			layer = pixelCNN.inputLayer(nOutputPlane, kernel_size, 1, self.channels),
			nOutputPlane = nOutputPlane
		}
	else
		self.layers[#self.layers+1] = {
			layer = pixelCNN.GatedPixelConvolution(
				self.layers[#self.layers].nOutputPlane, nOutputPlane,
				kernel_size, 1, #self.layers+1, self.channels, self.force_residual),
			nOutputPlane = nOutputPlane
		}
	end

	self.layers[#self.layers].name = "pixelCNN_l" .. #self.layers
end

function Helper:generate(name)
	-- Add output layer
	local output = pixelCNN.outputLayer(self.layers[#self.layers].nOutputPlane, self.channels)
	local model = nn.Sequential()
	model.name = name

	local function check(model, layer, idx)
		-- Try to run output through it so we can better debug the final assembly.
		local status, err = pcall(function() model:forward(self.sample_input) end)
		if err then
			print("pixelCNN generation failed at layer " .. idx .. ": " .. tostring(layer))
			error(err)
		end
	end

	-- Do it to it
	for idx,layer in pairs(self.layers) do
		model:add(layer.layer)
		check(model, layer, idx)		
	end
	model:add(output)
	check(model, output, #self.layers + 1)

	return model
end



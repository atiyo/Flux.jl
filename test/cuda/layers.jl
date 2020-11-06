# Test layers and data/model movements on and off the GPU
# Add tests for layers and their gradients on the GPU
# Most of the forward passes should be fine being applied
# to bitstype objects, but this gives higher coverage for our use-cases
# Check that getting the gradients does not throw

# generic movement tests
@testset "Basic GPU Movement" begin
  @test gradient(x -> sum(gpu(x)), rand(3,3)) isa Tuple
  @test gradient(x -> sum(cpu(x)), gpu(rand(3,3))) isa Tuple
end

# TODO: These layers get into scalar indexing
# `AlphaDropout` throws a compilation error on GPUs,
# whereas, the rest are scalar indexing issues.
const BROKEN_LAYERS = Union{DepthwiseConv,
                            AlphaDropout,
                            InstanceNorm,
                            GroupNorm}

function gpu_gradtest(name::String, layers::Vector, x_cpu=nothing, args...; test_cpu=true)
  isnothing(x_cpu) && error("Missing input to test the layers against.")
  @testset "$name GPU grad tests" begin
    for layer in layers
      @testset "$layer GPU grad test" begin

        # compute output and grad of parameters
        l_cpu = layer(args...)
        ps_cpu = Flux.params(l_cpu)
        y_cpu, back_cpu = pullback(() -> sum(l_cpu(x_cpu)), ps_cpu)
        gs_cpu = back_cpu(1f0)

        x_gpu = gpu(x_cpu)
        l_gpu = l_cpu |> gpu
        ps_gpu = Flux.params(l_gpu)

        if l_gpu isa BROKEN_LAYERS
          @test_broken gradient(() -> sum(l_gpu(x_gpu)), ps_gpu) isa Flux.Zygote.Grads
        else
          y_gpu, back_gpu = pullback(() -> sum(l_gpu(x_gpu)), ps_gpu)
          gs_gpu = back_gpu(1f0) # TODO many layers error out when backprop int 1, should fix

          # compute grad of input
          xg_cpu = gradient(x -> sum(l_cpu(x)), x_cpu)[1]
          xg_gpu = gradient(x -> sum(l_gpu(x)), x_gpu)[1]

          # test 
          if test_cpu
            @test y_gpu ≈ y_cpu   rtol=1e-4 atol=1e-4
            @test Array(xg_gpu) ≈ xg_cpu   rtol=1e-4 atol=1e-4
          end
          @test gs_gpu isa Flux.Zygote.Grads
          for (p_cpu, p_gpu) in zip(ps_cpu, ps_gpu)
            @test gs_gpu[p_gpu] isa Flux.CUDA.CuArray
            if test_cpu
              @test Array(gs_gpu[p_gpu]) ≈ gs_cpu[p_cpu]   rtol=1e-4 atol=1e-4
            end
          end
        end
      end
    end
  end
end

r = rand(Float32, 28, 28, 1, 1)
conv_layers = [Conv, ConvTranspose, CrossCor, DepthwiseConv]
gpu_gradtest("Conv", conv_layers, r, (2,2), 1=>3)

pooling_layers = [MaxPool, MeanPool]
gpu_gradtest("Pooling", pooling_layers, r, (2,2))

adaptive_pooling_layers = [AdaptiveMaxPool, AdaptiveMeanPool]
gpu_gradtest("AdaptivePooling", adaptive_pooling_layers, r, (7,7))

dropout_layers = [Dropout, AlphaDropout]
gpu_gradtest("Dropout", dropout_layers, r, 0.5f0; test_cpu=false)

norm_layers = [LayerNorm, BatchNorm]
gpu_gradtest("Normalising", norm_layers, rand(Float32, 28,28,3,1), 1)

instancenorm = [InstanceNorm]
gpu_gradtest("InstanceNorm", instancenorm, r, 1)

groupnorm = [GroupNorm]
gpu_gradtest("GroupNorm", groupnorm, rand(Float32, 28,28,3,1), 3, 1)

@testset "function layers" begin
  x = rand(3,3)
  gpu_gradtest(x -> sum(Flux.normalise(x; dims=1)), x)
  gpu_gradtest(x -> sum(Flux.normalise(x; dims=2)), x)
  gpu_gradtest(x -> sum(Flux.normalise(x)), x)
end

module MCMC

using ..Model
#include("Synthetic.jl")
using DataFrames
using Distributions

# TODO move these to model/log_prob.jl
star_param_names = ["lnr", "cug", "cgr", "cri", "ciz", "ra", "dec"]
galaxy_param_names = [star_param_names; ["gdev", "gaxis", "gangle", "gscale"]]


"""
Make a synthetic log pdf --- based on Synthetic.jl
"""
function make_star_logpdf_synth(images::Vector{Image},
                                patches::Matrix{SkyPatch},
                                fixed_pos::Array{Float64,1})
    # define star prior log probability density function
    prior = Model.construct_prior()
    subprior = prior.star

    function star_logprior(state::Vector{Float64})
        brightness, colors, u = state[1], state[2:5], state[6:end]
        return Model.color_logprior(brightness, colors, prior, true)
    end

    # define star log joint probability density function
    function star_logpdf(state::Vector{Float64})
        #println(" callign synth star logpdf")
        ll_prior = star_logprior(state)

        # convert state to catalog entry --- render expected image
        brightness, colors, position = state[1], state[2:5], state[6:end]
        fluxes = Model.colors_to_fluxes(brightness, colors)
        ce = Model.CatalogEntry(fixed_pos, true, fluxes, fluxes,
                                .1, .7, pi/4, 4., "ll", 0);

        # render expected image
        mod_images = Synthetic.gen_blob(images, [ce]; expectation=true)

        # first render start state and data image --- make sure they overlap

        # compute Poisson LL for each Pixel
        ll = 0
        for n in 1:length(mod_images)
            mimg = mod_images[n]
            dimg = images[n]
            for w in 1:mimg.W, h in 1:mimg.H
                # note that images are indexed HEIGHT, WIDTH (row, col or y, x)
                pix_lam  = mimg.pixels[h,w]
                pix_dat  = dimg.pixels[h,w]
                #pixel_ll = logpdf(Distributions.Poisson(pix_lam),
                #                  round(Int, pix_dat))
                pixel_ll = pix_dat*log(pix_lam) - pix_lam
                ll += pixel_ll
            end
        end
        return ll + ll_prior
    end

    return star_logpdf, star_logprior
end


"""
Main star + galaxy MCMC functions --- creates logpdf and runs
mcmc sampler
"""
function run_single_star_mcmc(sources::Vector{CatalogEntry},
                              images::Vector{Image},
                              patches::Matrix{SkyPatch},
                              active_sources::Vector{Int},
                              psf_K::Int64;
                              num_samples::Int64=1000,
                              num_chains::Int64=5,
                              num_warmup::Int64=200,
                              chain_prop_scale::Float64=.05,
                              warmup_prop_scale::Float64=.1,
                              print_skip::Int64=250)

    println("--- chain prop scale: ", chain_prop_scale)
    # turn list of catalog entries a list of LatentStateParams
    # and create logpdf function handle
    source_states = [Model.catalog_entry_to_latent_state_params(s)
                     for s in sources]
    S = length(source_states)
    N = length(images)
    #star_logpdf, star_logprior =
    ##    Model.make_star_logpdf(images, S, N, source_states,
    #                           patches, active_sources, psf_K)
    ce = sources[1]
    fixed_pos = ce.pos
    star_logpdf, star_logprior = 
          make_star_logpdf_synth(images, patches, fixed_pos)

    # initialize star params
    star_state = Model.extract_star_state(source_states[1])
    best_ll = star_logpdf(star_state)
    println(" initial log posterior: ", best_ll)
    println(" initial log prior: ", star_logprior(star_state))

    # determine proposal scale for each dimension --- estimate the
    # diagonal of the hessian

    # run multiple chains
    chains, logprobs = [], []
    for c in 1:num_chains
      # initialize a star state (around the existing catalog entry)
      println("---- chain ", c, " ----")
      th0 = init_star_params(star_state)
      samples, lls =
        run_mh_sampler_with_warmup(star_logpdf, th0,
                                   num_samples,
                                   num_warmup;
                                   print_skip=print_skip,
                                   keep_warmup=true,
                                   warmup_prop_scale=warmup_prop_scale,
                                   chain_prop_scale=chain_prop_scale)

      thlast = samples[end,:]
      println(" mixed value, log post, log prior ",
              star_logpdf(thlast), ", ", star_logprior(thlast))

      push!(chains, samples[(num_warmup+1):end, :])
      push!(logprobs, lls[(num_warmup+1):end])

      # report PSRF after c = 3 chains
      if c > 2
        psrfs = MCMC.potential_scale_reduction_factor(chains)
        println(" potential scale red factor", psrfs)
      end
    end

    return chains, logprobs
end


function run_single_galaxy_mcmc(sources::Vector{CatalogEntry},
                                images::Vector{Image},
                                patches::Matrix{SkyPatch},
                                active_sources::Vector{Int},
                                psf_K::Int64;
                                num_samples::Int64=1000,
                                num_chains::Int64=5,
                                num_warmup::Int64=200,
                                prop_scale::Float64=.01,
                                print_skip::Int64=250)
    source_states = [Model.catalog_entry_to_latent_state_params(s)
                     for s in sources]
    gal_logpdf, gal_logprior =
        Model.make_galaxy_logpdf(images, S, N,
                                 source_states,
                                 patches, active_sources,
                                 psf_K)

    # initialize star params
    gal_state = Model.extract_galaxy_state(source_states[1])
    println(gal_state)
    best_ll = gal_logpdf(gal_state)

    # run star slic esampler for 
    gal_sim = run_slice_sampler(gal_logpdf, gal_state,
                                 num_samples, galaxy_param_names)
    gal_sim

end


function init_star_params(star_params::Vector{Float64};
                          radec_scale::Float64=1e-5)
    th0 = copy(star_params)
    #for ii in 1:5
    #  th0[ii] += .01*randn()
    #end
    #th0[6:7] += radec_scale*randn(2)
    return th0
end


###########
# Helpers #
###########

"""
Rudimentary proposal scale determination --- given a log probability
function, this numerically determines the diagonal of the Hessian, and
returns its inverse 1/diag(Hessian).

This is meant to capture the relative scale between the different 
parameters for the log likelihood function, used to determine
reasonable proposals
"""
function compute_proposal_scale(lnpdf::Function,
                                th0::Vector{Float64})
    # univariate derivative function generator
    function numgrad(f::Function, d::Int64)
        function df(th::Vector{Float64})
          de      = 1e-6
          the     = copy(th)
          the[d] += de
          return (lnpdf(the) - lnpdf(th)) / de
        end
        return df
    end

    # for each dimension, numerically compute elementwise gradient twice
    D = length(th0)
    Hdiag = zeros(D)
    for d in 1:D
        df  = numgrad(lnpdf, d)
        ddf = numgrad(df, d)
        Hdiag[d] = ddf(th0)
    end
    return 1./ sqrt.(abs.(Hdiag))
end


"""
Run single metropolis hastings chain --- 
  - with warmup first computes a proposal scale based on 
    starting th0, and then re-adjusts the proposal scale after
    the target proposal
"""
function run_mh_sampler_with_warmup(lnpdf::Function,
                                    th0::Vector{Float64},
                                    N::Int64,
                                    warmup::Int64;
                                    print_skip::Int64=100,
                                    keep_warmup::Bool=false,
                                    warmup_prop_scale::Float64=.1,
                                    chain_prop_scale::Float64=.05)
    println("warming up .... ")
    #prop_scale   = warmup_prop_scale*compute_proposal_scale(lnpdf, th0)
    prop_scale   = warmup_prop_scale * ones(length(th0))
    wchain, wlls = run_mh_sampler(lnpdf, th0, warmup, prop_scale;
                                  print_skip=print_skip)

    println("running sampler .... ")
    th0 = wchain[end,:]
    #prop_scale = chain_prop_scale*compute_proposal_scale(lnpdf, th0)
    prop_scale = chain_prop_scale * ones(length(th0))
    chain, lls = run_mh_sampler(lnpdf, th0, N, prop_scale;
                                print_skip=print_skip)

    if keep_warmup
        chain, lls = vcat([wchain, chain]...), vcat([wlls, lls]...)
    end
    return chain, lls
end

function run_mh_sampler(lnpdf::Function,
                        th0::Vector{Float64},
                        N::Int64,
                        prop_scale::Vector{Float64};
                        print_skip::Int=100)

    # stack of samples, log probs, and accepts
    D = length(th0)
    samples = zeros(Float64, (N, D))
    lnprobs = zeros(Float64, N)
    naccept = 0

    # run chain for N steps
    thcurr = th0
    llcurr = lnpdf(thcurr)
    @printf "  iter : \t loglike \t acc. rat \t num acc. \n"
    for i in 1:N
      if mod(i, print_skip) == 0
          @printf "   %d   : \t %2.4f \t %2.4f \t %d \n" i llcurr (float(naccept)/float(i)) naccept
      end

      # propose sample
      thprop = thcurr + prop_scale .* randn(D)
      llprop = lnpdf(thprop)

      # acceptance ratio
      aratio = (llprop - llcurr)
      if log(rand()) < aratio
          naccept += 1
          thcurr = thprop
          llcurr = llprop
      end

      # store samples
      samples[i,:] = thcurr
      lnprobs[i]   = llcurr
    end

    return samples, lnprobs
end


function run_slice_sampler(lnpdf::Function,
                           th0::Vector{Float64},
                           N::Int64)

end



"""
Potential Scale Reduction Factor --- computes a metric that 
assesses how well MCMC chains have mixed.  Followed the formula
as written at the following website:
http://blog.stata.com/2016/05/26/gelman-rubin-convergence-diagnostic-using-multiple-chains/
"""
function potential_scale_reduction_factor(chains)
    # each chain has to be size N x D, we have M chains
    N, D  = size(chains[1])
    M     = length(chains)

    # mean and variance of each chain
    means = vcat([mean(s, 1) for s in chains]...)
    vars  = vcat([var(s, 1)  for s in chains]...)

    # grand mean
    gmu   = mean(means, 1)

    # between chain variance:w
    B = float(N)/(float(M)-1)*sum( broadcast(-, means, gmu).^2, 1)

    # average within chain variance
    W = mean(vars, 1)

    # compute PRSF ratio
    Vhat = (float(N)-1.)/float(N) * W + (float(M)+1)/float(N*M) * B
    psrf = Vhat ./ W
    return psrf
end


"""
Convert `chains` (list of sample arrays), `logprobs` (list of 
log-likelihood traces) and `colnames` (list of parameter names for chains)
into a DataFrame object --- for saving and plotting
"""
function chains_to_dataframe(chains, logprobs, colnames)
    # sample, lls, chain identifier all in arrays
    samples    = vcat(chains...)
    sample_lls = vcat(logprobs...)
    chain_id   = vcat([s*ones(Integer, size(chains[s], 1))
                       for s in 1:length(chains)]...)

    # convert to data frame, rename variables
    sdf = convert(DataFrame, samples)
    rename!(sdf, names(sdf), [Symbol(s) for s in colnames])

    # add lls, chain index
    sdf[:lls]   = sample_lls
    sdf[:chain] = chain_id
    return sdf
end


end

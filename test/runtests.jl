#!/usr/bin/env julia

using Base.Test
using Distributions
using ForwardDiff
using StaticArrays

using Celeste: Model, DeterministicVI

import Celeste: Infer, DeterministicVI, ParallelRun
import Celeste: PSF, SDSSIO, SensitiveFloats, Transform
import Celeste.SensitiveFloats.clear!
import Celeste.SDSSIO: RunCamcolField

include(joinpath(Pkg.dir("Celeste"), "test", "SampleData.jl"))

using SampleData

anyerrors = false

wd = pwd()
# Ensure that test images are available.
const datadir = joinpath(Pkg.dir("Celeste"), "test", "data")
cd(datadir)
run(`make`)
run(`make RUN=4263 CAMCOL=5 FIELD=119`)
# Ensure GalSim test images are available.
const galsim_benchmark_dir = joinpath(Pkg.dir("Celeste"), "benchmark", "galsim")
cd(galsim_benchmark_dir)
run(`make fetch`)
cd(wd)

# Check whether to run time-consuming tests.
long_running_flag = "--long-running"
test_long_running = long_running_flag in ARGS
test_files = setdiff(ARGS, [ long_running_flag ])

if length(test_files) > 0
    testfiles = ["test_$(arg).jl" for arg in test_files]
else
    testdir = joinpath(Pkg.dir("Celeste"), "test")
    testfiles = filter(r"test_.*\.jl", readdir(testdir))
end

if !test_long_running
    warn("Skipping long running tests.  ",
         "To test everything, run tests with the flag ", long_running_flag)
end


for testfile in testfiles
    try
        println("Running ", testfile)
        @time include(testfile)
        println("\t\033[1m\033[32mPASSED\033[0m: $(testfile)")
    catch e
        anyerrors = true
        println("\t\033[1m\033[31mFAILED\033[0m: $(testfile)")
        rethrow()  # Fail fast.
    end
end

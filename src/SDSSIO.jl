# Functions for loading FITS files from the SloanDigitalSkySurvey.
module SDSSIO

import FITSIO
import WCS
using CodecZlib
using CodecBzip2

import ..Log
import ..Model: RawPSF, Image, CatalogEntry, eval_psf, SkyIntensity
import ..PSF
import Base.convert, Base.getindex
export PlainFITSStrategy, RunCamcolField

# types of things to mask in read_mask().
const DEFAULT_MASK_PLANES = ["S_MASK_INTERP",  # bad pixel (was interpolated)
                             "S_MASK_SATUR",  # saturated
                             "S_MASK_CR",  # cosmic ray
                             "S_MASK_GHOST"]  # electronics artifacts

const BAND_CHAR_TO_NUM = Dict('u'=>1, 'g'=>2, 'r'=>3, 'i'=>4, 'z'=>5)


struct RunCamcolField
    run::Int16
    camcol::UInt8
    field::Int16
end


function RunCamcolField(run::String, camcol::String, field::String)
    RunCamcolField(
        parse(Int16, run),
        parse(UInt8, camcol),
        parse(Int16, field))
end


abstract type SDSSImageDesc; end

struct PhotoObj <: SDSSImageDesc
    rcf::RunCamcolField
end
struct PhotoField <: SDSSImageDesc
    run::Int16
    camcol::UInt8
end
struct PsField <: SDSSImageDesc
    rcf::RunCamcolField
end
struct Frame <: SDSSImageDesc
    rcf::RunCamcolField
    band::Char
end
struct Mask <: SDSSImageDesc
    rcf::RunCamcolField
    band::Char
end
struct FieldExtents <: SDSSImageDesc; end
rcf(img::SDSSImageDesc) = img.rcf
rcf(img::PhotoField) = RunCamcolField(img.run, img.camcol, -1)

filename(p::PhotoObj) = "photoObj-$(dec(p.rcf.run,6))-$(dec(p.rcf.camcol))-$(dec(p.rcf.field,4)).fits"
filename(p::PhotoField) = "photoField-$(dec(p.run,6))-$(p.camcol).fits"
filename(p::PsField) = "psField-$(dec(p.rcf.run,6))-$(p.rcf.camcol)-$(dec(p.rcf.field,4)).fit"
filename(p::Frame) = "frame-$(p.band)-$(dec(p.rcf.run,6))-$(p.rcf.camcol)-$(dec(p.rcf.field,4)).fits"
filename(p::Mask) = "fpM-$(dec(p.rcf.run,6))-$(p.band)$(p.rcf.camcol)-$(dec(p.rcf.field,4)).fit"
filename(p::FieldExtents) = "field_extents.fits"

"""
read_sky(hdu)

Construct an image of the sky from the sky HDU of a SDSS \"frame\" file.
This is typically the 3rd HDU of the file.
"""
function read_sky(hdu::FITSIO.TableHDU)
    sky_small = squeeze(read(hdu, "ALLSKY"), 3)::Array{Float32, 2}
    sky_x = vec(read(hdu, "XINTERP"))::Vector{Float32}
    sky_y = vec(read(hdu, "YINTERP"))::Vector{Float32}

    # convert sky interpolation coordinates from 0-indexed to 1-indexed
    for i=1:length(sky_x)
        sky_x[i] += 1.0f0
    end
    for i=1:length(sky_y)
        sky_y[i] += 1.0f0
    end

    # sky intensity has to be strictly greater than 0 for the elbo
    # to be defined
    @assert all((x)-> x > 1e-12, sky_small)

    return sky_small, sky_x, sky_y
end

"""
read_frame(fname)

Read an SDSS \"frame\" FITS file and return a 4-tuple:

- `image`: sky-subtracted and calibrated 2-d image.
- `calibration`: 1-d \"calibration\".
- `sky`: 2-d sky that was subtracted.
- `wcs`: WCSTransform constructed from image header.
"""
function read_frame(strategy, rcf, b)
    f = readFITS(strategy, Frame(rcf, b))
    hdr = FITSIO.read_header(f[1], String)::String
    image = read(f[1])::Array{Float32, 2}  # sky-subtracted & calibrated data, in nMgy
    calibration = read(f[2])::Vector{Float32}
    sky_small, sky_x, sky_y = read_sky(f[3])
    close(f)

    sky = SkyIntensity(sky_small, sky_x, sky_y, calibration)

    wcs = WCS.from_header(hdr)[1]

    return image, calibration, sky, wcs
end


"""
read_field_gains(fname, fieldnum)

Return the image gains for field number `fieldnum` in an SDSS
\"photoField\" file `fname`.
"""
function read_field_gains(strategy, rcf)
    fieldnum = rcf.field
    f = readFITS(strategy, PhotoField(rcf.run, rcf.camcol))
    fieldnums = read(f[2], "FIELD")::Vector{Int32}
    gains = read(f[2], "GAIN")::Array{Float32, 2}
    close(f)

    # Find first occurance of `fieldnum` and return the corresponding gain.
    for i=1:length(fieldnums)
        if fieldnums[i] == fieldnum
            bandgains = gains[:, i]
            return Dict(zip("ugriz", bandgains))
        end
    end

    error("field number $fieldnum not found in file: $fname")
end


"""
read_mask(fname[, mask_planes])

Read a \"fpM\"-format SDSS file and return masked image ranges,
based on `mask_planes`. Returns two `Vector{UnitRange{Int}}`,
giving the range of x and y indicies to be masked.
"""
function read_mask(strategy, rcf, b, mask_planes=DEFAULT_MASK_PLANES; data=nothing)
    f = readFITS(strategy, Mask(rcf, b))

    # The last (12th) HDU contains a key describing what each of the
    # other HDUs are. Use this to find the indicies of all the relevant
    # HDUs (those with attributeName matching a value in `mask_planes`).
    value = read(f[12], "Value")::Vector{Int32}
    def = read(f[12], "defName")::Vector{String}
    attribute = read(f[12], "attributeName")::Vector{String}

    # initialize return values
    xranges = UnitRange{Int}[]
    yranges = UnitRange{Int}[]

    # Loop over keys and check if each is a mask plane we're interested in
    # (those with defName == "S_MASKTYPE" and "attributeName" in mask_planes).
    # If so, read from the corresponding HDU and construct ranges to mask.
    for i=1:length(value)
        if (def[i] == "S_MASKTYPE" && attribute[i] in mask_planes)

            # `value` starts from 0, but first table hdu is hdu number 2
            hdunum = value[i] + 2

            cmin = read(f[hdunum], "cmin")::Vector{Int32}
            cmax = read(f[hdunum], "cmax")::Vector{Int32}
            rmin = read(f[hdunum], "rmin")::Vector{Int32}
            rmax = read(f[hdunum], "rmax")::Vector{Int32}

            # "c" ("column") refers to mask's NAXIS1 (x axis);
            # "r" ("row") refers to mask's NAXIS2 (y axis).
            # cmin/cmax and rmin/rmax are 0-based and inclusive, so we add 1
            # to both.
            for j=1:length(cmin)
                push!(xranges, (cmin[j] + 1):(cmax[j] + 1))
                push!(yranges, (rmin[j] + 1):(rmax[j] + 1))
            end
        end
    end
    close(f)

    return xranges, yranges
end


struct RawImage
    rcf::RunCamcolField
    b::Int  # band index
    pixels::Matrix{Float32} # in nMgy, sky-subtracted and calibrated
    calibration::Vector{Float32}
    sky::SkyIntensity
    wcs::WCS.WCSTransform
    gain::Float32
    raw_psf_comp::RawPSF
end


"""
Read a SDSS run/camcol/field into a vector of RawImages
"""
function load_raw_images(strategy, rcf::RunCamcolField, drop_quickly::Bool = false)
    # read gain for each band
    gains = read_field_gains(strategy, rcf)

    # open FITS file containing PSF for each band
    psffile = readFITS(strategy, PsField(rcf))

    raw_images = Vector{RawImage}(5)

    for (b, band) in enumerate(['u', 'g', 'r', 'i', 'z'])
        # load image data
        r = parse_image(strategy, rcf, b, psffile, band, gains)
        if !drop_quickly
            raw_images[b] = r
        end
    end
    close(psffile)

    return raw_images
end

function parse_image(strategy, rcf, b, psffile, band, gains)
    # load image data
    pixels, calibration, sky, wcs = read_frame(strategy, rcf, band)

    # read mask
    mask_xranges, mask_yranges = read_mask(strategy, rcf, band)

    # apply mask
    for i=1:length(mask_xranges)
        pixels[mask_xranges[i], mask_yranges[i]] = NaN
    end

    # read the psf
    raw_psf_comp = read_psf(psffile, band)

    # Set it to use a constant background but include the non-constant data.
    r = RawImage(rcf, b,
                        pixels, calibration, sky, wcs,
                        gains[band], raw_psf_comp)
    r
end


"""
Load all the images for multiple rcfs
"""
function load_raw_images(strategy, rcfs::Vector{RunCamcolField}, drop_quickly::Bool = false)
    raw_images = RawImage[]

    for rcf in rcfs
        #Log.info("loading images for $rcf")
        rcf_raw_images = SDSSIO.load_raw_images(strategy, rcf, drop_quickly)
        append!(raw_images, rcf_raw_images)
    end

    raw_images
end


"""
Converts a raw image to an image by fitting the PSF, a mixture of Gaussians.
"""
function convert(::Type{Image}, r::RawImage)
    H, W = size(r.pixels)

    psfstamp = eval_psf(r.raw_psf_comp, H / 2., W / 2.)
    celeste_psf = PSF.fit_raw_psf_for_celeste(psfstamp, 2)[1]

    # scale pixels to raw electron counts
    @assert size(r.pixels, 1) == length(r.calibration)
    @inbounds for j=1:size(r.pixels, 2), i=1:size(r.pixels, 1)
        sky_ij = r.sky[i, j]
        r.pixels[i, j] = (r.gain / r.calibration[i]) * (r.pixels[i, j] + sky_ij)
    end

    nelec_per_nmgy = r.gain ./ r.calibration

    Image(H, W, r.pixels, r.b, r.wcs, celeste_psf,
          r.rcf.run, r.rcf.camcol, r.rcf.field,
          r.sky, nelec_per_nmgy, r.raw_psf_comp)
end

# -----------------------------------------------------------------------------
# PSF-related functions

"""
read_psf(fitsfile, band)

Read PSF components for the given band ('u', 'g', 'r', 'i', or 'z')
from the open FITSIO.FITS instance `fitsfile`, which should be a SDSS
\"psField\" file, and return a RawPSF instance representing the spatially
variable PSF.
"""
function read_psf(fitsfile::FITSIO.FITS, band::Char)

    # get the HDU, assuming PSF hdus are in order after primary header
    extnum = 1 + BAND_CHAR_TO_NUM[band]
    hdu = fitsfile[extnum]::FITSIO.TableHDU

    nrows = FITSIO.read_key(hdu, "NAXIS2")[1]::Int
    nrow_b = Int((read(hdu, "nrow_b")::Vector{Int32})[1])
    ncol_b = Int((read(hdu, "ncol_b")::Vector{Int32})[1])
    rnrow = (read(hdu, "rnrow")::Vector{Int32})[1]
    rncol = (read(hdu, "rncol")::Vector{Int32})[1]
    cmat_raw = read(hdu, "c")::Array{Float32, 3}
    rrows_raw = read(hdu, "rrows")::Array{Array{Float32,1},1}

    # Only the first (nrow_b, ncol_b) submatrix of cmat is used for
    # reasons obscure to the author.
    cmat = Array{Float64,3}(nrow_b, ncol_b, size(cmat_raw, 3))
    for k=1:size(cmat_raw, 3), j=1:nrow_b, i=1:ncol_b
        cmat[i, j, k] = cmat_raw[i, j, k]
    end

    # convert rrows to Array{Float64, 2}, assuming each row is the same length.
    rrows = Matrix{Float64}(length(rrows_raw[1]), length(rrows_raw))
    for i=1:length(rrows_raw)
        rrows[:, i] = rrows_raw[i]
    end

    return RawPSF(rrows, rnrow, rncol, cmat)
end


"""
Read a source catalog from an SDSS \"photoObj\" FITS file for a given
run/camcol/field combination, returning a Vector of columns and a Vector
of column names.

This is currently pretty specific to Celeste because it returns only columns
that we're interested in, and it does some transformations of some of the
columns.

The photoObj file format is documented here:
https://data.sdss.org/datamodel/files/BOSS_PHOTOOBJ/RERUN/RUN/CAMCOL/photoObj.html
"""
read_photoobj(strategy, rcf, band::Char='r') =
    read_photoobj(readFITS(strategy, PhotoObj(rcf)), band, true)

function read_photoobj(f::FITSIO.FITS, band::Char='r', close_file=true)
    b = BAND_CHAR_TO_NUM[band]

    # sometimes the expected table extension is only an empty generic FITS
    # header, indicating no objects. We check explicitly for this case here
    # and return an empty table
    if (length(f) < 2) || (!isa(f[2], FITSIO.TableHDU))
        catalog = Dict("objid"=>String[],
                       "ra"=>Float64[],
                       "dec"=>Float64[],
                       "thing_id"=>Int32[],
                       "mode"=>UInt8[],
                       "is_star"=>BitVector(),
                       "is_gal"=>BitVector(),
                       "frac_dev"=>Float32[],
                       "ab_exp"=>Float32[],
                       "theta_exp"=>Float32[],
                       "phi_exp"=>Float32[],
                       "ab_dev"=>Float32[],
                       "theta_dev"=>Float32[],
                       "phi_dev"=>Float32[],
                       "phi_offset"=>Float32[])
        for (b, n) in BAND_CHAR_TO_NUM
            catalog["psfflux_$b"] = Float32[]
            catalog["compflux_$b"] = Float32[]
            catalog["expflux_$b"] = Float32[]
            catalog["devflux_$b"] = Float32[]
        end
        return catalog
    end

    hdu = f[2]::FITSIO.TableHDU

    objid = read(hdu, "objid")::Vector{String}
    ra = read(hdu, "ra")::Vector{Float64}
    dec = read(hdu, "dec")::Vector{Float64}
    mode = read(hdu, "mode")::Vector{UInt8}
    thing_id = read(hdu, "thing_id")::Vector{Int32}

    # Get "bright" objects.
    # (In objc_flags, the bit pattern Int32(2) corresponds to bright objects.)
    objc_flags = read(hdu, "objc_flags")::Vector{Int32}
    objc_flags2 = read(hdu, "objc_flags2")::Vector{Int32}

    # bright, saturated, or large
    bad_flags1 = objc_flags .& UInt32(1^2 + 2^18 + 2^24) .!= 0

    # nopeak, DEBLEND_DEGENERATE, or saturated center
    bad_flags2 = objc_flags2 .& UInt32(2^14 + 2^18 + 2^11) .!= 0

    has_child = read(hdu, "nchild")::Vector{Int16} .> 0

    # 6 = star, 3 = galaxy, others can be ignored.
    objc_type = read(hdu, "objc_type")::Vector{Int32}
    is_star = objc_type .== 6
    is_gal = objc_type .== 3
    bad_type = ((!).(is_star .| is_gal))

    fracdev = vec((read(hdu, "fracdev")::Matrix{Float32})[b, :])

    # determine mask for rows
    has_dev = fracdev .> 0.
    has_exp = fracdev .< 1.
    is_comp = (has_dev .& has_exp)
    is_bad_fracdev = ((fracdev .< 0.) .| (fracdev .> 1))

    # TODO: We don't really want to exclude objects entirely just for being
    # bright: we just don't want to use for scoring (since
    # they're very saturated, presumably).
    mask = (!).(is_bad_fracdev .| bad_type .| bad_flags1 .| bad_flags2 .| has_child)

    # Read the fluxes.
    # Record the cmodelflux if the galaxy is composite, otherwise use
    # the flux for the appropriate type.
    psfflux = read(hdu, "psfflux")::Matrix{Float32}
    cmodelflux = read(hdu, "cmodelflux")::Matrix{Float32}
    devflux = read(hdu, "devflux")::Matrix{Float32}
    expflux = read(hdu, "expflux")::Matrix{Float32}

    # We actually only store the following properties for the given band
    # (see below in Dict construction) NB: the phi quantites in tractor are
    # multiplied by -1.
    phi_dev_deg = read(hdu, "phi_dev_deg")::Matrix{Float32}
    phi_exp_deg = read(hdu, "phi_exp_deg")::Matrix{Float32}
    phi_offset = read(hdu, "phi_offset")::Matrix{Float32}

    theta_dev = read(hdu, "theta_dev")::Matrix{Float32}
    theta_exp = read(hdu, "theta_exp")::Matrix{Float32}

    ab_exp = read(hdu, "ab_exp")::Matrix{Float32}
    ab_dev = read(hdu, "ab_dev")::Matrix{Float32}

    close_file && close(f)

    # construct result catalog
    catalog = Dict("objid"=>objid[mask],
                   "ra"=>ra[mask],
                   "dec"=>dec[mask],
                   "thing_id"=>thing_id[mask],
                   "mode"=>mode[mask],
                   "is_star"=>is_star[mask],
                   "is_gal"=>is_gal[mask],
                   "frac_dev"=>fracdev[mask],
                   "ab_exp"=>vec(ab_exp[b, mask]),
                   "theta_exp"=>vec(theta_exp[b, mask]),
                   "phi_exp"=>vec(phi_exp_deg[b, mask]),
                   "ab_dev"=>vec(ab_dev[b, mask]),
                   "theta_dev"=>vec(theta_dev[b, mask]),
                   "phi_dev"=>vec(phi_dev_deg[b, mask]),
                   "phi_offset"=>vec(phi_offset[b, mask]))
    for (b, n) in BAND_CHAR_TO_NUM
        catalog["psfflux_$b"] = vec(psfflux[n, mask])
        catalog["compflux_$b"] = vec(cmodelflux[n, mask])
        catalog["expflux_$b"] = vec(expflux[n, mask])
        catalog["devflux_$b"] = vec(devflux[n, mask])
    end

    # left over note about fluxes above: Use the cmodelflux if the
    # galaxy is composite, otherwise use the flux for the appropriate type.

    return catalog
end


"""
Convert from a catalog in dictionary-of-arrays, as returned by
read_photoobj to Vector{CatalogEntry}.
"""
function convert(::Type{Vector{CatalogEntry}}, catalog::Dict)
    out = CatalogEntry[]

    for i=1:length(catalog["objid"])
        worldcoords = [catalog["ra"][i], catalog["dec"][i]]
        frac_dev = catalog["frac_dev"][i]

        # Fill star and galaxy flux
        star_fluxes = zeros(5)
        gal_fluxes = zeros(5)
        for (j, band) in enumerate(['u', 'g', 'r', 'i', 'z'])
            # Make negative fluxes positive.
            psfflux = max(catalog["psfflux_$band"][i], 1e-6)
            devflux = max(catalog["devflux_$band"][i], 1e-6)
            expflux = max(catalog["expflux_$band"][i], 1e-6)

            # galaxy flux is a weighted sum of the two components.
            star_fluxes[j] = psfflux
            gal_fluxes[j] = frac_dev * devflux + (1.0 - frac_dev) * expflux
        end

        # For shape parameters, we use the dominant component (dev or exp)
        usedev = frac_dev > 0.5
        fits_ab = usedev? catalog["ab_dev"][i] : catalog["ab_exp"][i]
        fits_phi = usedev? catalog["phi_dev"][i] : catalog["phi_exp"][i]
        fits_theta = usedev? catalog["theta_dev"][i] : catalog["theta_exp"][i]

        # effective radius
        re_arcsec = max(fits_theta, 1. / 30)
        re_pixel = re_arcsec / 0.396

        fits_phi -= catalog["phi_offset"][i]

        # fits_phi is now degrees counter-clockwise from vertical
        # in pixel coordinates.

        # Celeste's phi measures radians counter-clockwise from vertical.
        celeste_phi_rad = fits_phi * (pi / 180)

        entry = CatalogEntry(worldcoords, catalog["is_star"][i], star_fluxes,
                             gal_fluxes, frac_dev, fits_ab, celeste_phi_rad,
                             re_pixel)
        push!(out, entry)
    end

    return out
end


function assemble_catalog(rawcatalogs::Vector{Dict};
                          duplicate_policy=:primary)
    # Limit each catalog to primary objects and objects where thing_id != -1
    # (thing_id == -1 indicates that the matching process failed)
    for cat in rawcatalogs
        mask = (cat["thing_id"] .!= -1)
        if duplicate_policy == :primary
            mask = (mask .& (cat["mode"] .== 0x01))
        end
        for key in keys(cat)
            cat[key] = cat[key][mask]
        end
    end

    #for i in eachindex(fts)
    #    Log.info(string("field $(fts[i]): $(length(rawcatalogs[i]["objid"])) ",
    #            "filtered entries"))
    #end

    # Merge all catalogs together (there should be no duplicate objects,
    # because for each object there should only be one "primary" occurance.)
    rawcatalog = deepcopy(rawcatalogs[1])
    for i=2:length(rawcatalogs)
        for key in keys(rawcatalog)
            append!(rawcatalog[key], rawcatalogs[i][key])
        end
    end

    # check that there are no duplicate thing_ids (see above comment)
    if length(Set(rawcatalog["thing_id"])) < length(rawcatalog["thing_id"])
        error("Found one or more duplicate primary thing_ids in photoobj " *
              "catalogs")
    end

    # convert to celeste format catalog
    catalog = convert(Vector{CatalogEntry}, rawcatalog)

    return catalog
end


"""
read_photoobj_files(fieldids, dirs) -> Vector{CatalogEntry}

Combine photoobj catalogs for the given overlapping fields, returning a single
joined catalog.

The `duplicate_policy` argument controls how catalogs are joined.
With `duplicate_policy = :primary`, only primary objects are included in the
combined catalog.
With `duplicate_policy = :first`, only the first detection is included in the
combined catalog.
"""
function read_photoobj_files(strategy, fts::Vector{RunCamcolField};
                             duplicate_policy=:primary,
                             slurp::Bool = false, drop_quickly::Bool = false)
    @assert duplicate_policy == :primary || duplicate_policy == :first
    @assert duplicate_policy == :primary || length(fts) == 1

    #Log.info("reading photoobj catalogs for $(length(fts)) fields")

    # the code below assumes there is at least one field.
    if length(fts) == 0
        return CatalogEntry[]
    end

    # Read in all photoobj catalogs.
    rawcatalogs = Vector{Dict}(length(fts))
    for i in eachindex(fts)
        ft = fts[i]
        #Log.info("field $(fts[i]): reading $fname")
        po = read_photoobj(strategy, ft, 'r')
        if !drop_quickly
            rawcatalogs[i] = po
        end
    end

    if drop_quickly
        return CatalogEntry[]
    end

    return assemble_catalog(rawcatalogs; duplicate_policy=duplicate_policy)
end

# IO Strategies, these are specification objects fed in from external
abstract type IOStrategy end

struct PlainFITSStrategy <: IOStrategy
    stagedir::String
    dirlayout::Symbol
    compressed::Bool
    # Could be a string or rcf -> stagedir function
    rcf_stagedir
    slurp::Bool
end
PlainFITSStrategy(stagedir::String, slurp::Bool = false) = PlainFITSStrategy(stagedir, :celeste, false, stagedir, slurp)

function slurp_fits(fname)
    is_linux() || is_bsd() || error("Slurping not implemented on this OS")
    # Do this with explicit POSIX calls, to make sure to avoid
    # any well-intended, but ultimately unhelpful intermediate
    # buffering.
    fd = ccall(:open, Cint, (Ptr{UInt8}, Cint, Cint), fname, Base.Filesystem.JL_O_RDONLY, 0)
    systemerror("open($fname)", fd == -1)
    stat_struct = zeros(UInt8, ccall(:jl_sizeof_stat, Int32, ()))
    # Can't use Base.stat because threading
    ret = ccall(:jl_fstat, Cint, (Cint, Ptr{UInt8}), fd, stat_struct)
    ret == 0 || throw(Base.UVError("stat",r))
    size = Base.Filesystem.StatStruct(stat_struct).size
    data = Array{UInt8}(size)
    rsize = ccall(:read, Cint, (Cint, Ptr{UInt8}, Csize_t), fd, data, size)
    systemerror("read", rsize != size)
    r = ccall(:close, Cint, (Cint,), fd)
    systemerror("close", r == -1)
    data
end

function compute_fname(strategy::PlainFITSStrategy, img::SDSSImageDesc)
    isa(img, FieldExtents) && return (joinpath(strategy.stagedir, filename(img)), nothing)
    imgrcf = rcf(img)
    basedir = isa(strategy.rcf_stagedir, String) ? strategy.rcf_stagedir : strategy.rcf_stagedir(imgrcf)
    if strategy.dirlayout == :celeste
        subdir = "$basedir/$(imgrcf.run)/$(imgrcf.camcol)"
        !isa(img, PhotoField) && (subdir = joinpath(subdir, string(imgrcf.field)))
    elseif strategy.dirlayout == :sdss
        if typeof(img) <: Union{Mask, PsField}
            # Photometric reductions
            subdir = joinpath(basedir, "boss/photo/redux/301", "$(imgrcf.run)/objcs/$(imgrcf.camcol)")
        elseif typeof(img) <: PhotoField
            subdir = joinpath(basedir, "boss/photoObj/301", "$(imgrcf.run)")
        elseif typeof(img) <: PhotoObj
            subdir = joinpath(basedir, "boss/photoObj/301", "$(imgrcf.run)/$(imgrcf.camcol)")
        elseif typeof(img) <: Frame
            subdir = joinpath(basedir, "boss/photoObj/frames/301", "$(imgrcf.run)/$(imgrcf.camcol)")
        end
    end
    fname = joinpath(subdir, filename(img))
    compression = nothing
    (strategy.compressed && isa(img, Frame)) && (fname *= ".bz2"; compression = Bzip2Decompression())
    (strategy.compressed && isa(img, Mask)) && (fname *= ".gz"; compression = GzipDecompression())
    fname, compression
end

function readFITS(strategy::PlainFITSStrategy, img::SDSSImageDesc)
    fname, compression = compute_fname(strategy, img)
    if strategy.slurp || compression != nothing
        data = slurp_fits(fname)
        (compression != nothing) && (data = transcode(compression, data))
        return FITSIO.FITS(data)
    else
        return FITSIO.FITS(fname)
    end
end

abstract type NetworkIoStrategy <: IOStrategy; end

struct MasterRPCStrategy <: NetworkIoStrategy
    remote_strategy::IOStrategy
end

function readRawData(strategy, img)
    fname, compression = compute_fname(strategy, img)
    data = slurp_fits(fname)
    data, compression
end

function readFITS(strategy::MasterRPCStrategy, img::SDSSImageDesc)
    data, compression = remotecall_fetch(readRawData, 1, strategy.remote_strategy, img)
    (compression != nothing) && (data = transcode(compression, data))
    return FITSIO.FITS(data)
end


"""
Read a SDSS run/camcol/field into an array of Images.
"""
function load_field_images(strategy::IOStrategy, rcfs, drop_quickly::Bool = false)
    raw_images = SDSSIO.load_raw_images(strategy, rcfs, drop_quickly)

    N = length(raw_images)
    images = Vector{Image}(N)

    drop_quickly && return images

    #Threads.@threads for n in 1:N
    for n in 1:N
        try
            images[n] = convert(Image, raw_images[n])
        catch exc
            Log.exception(exc)
            rethrow()
        end
    end

    return images
end


end  # module

module BSDiff

export bsdiff, bspatch, bsindex

using SuffixArrays
using TranscodingStreams, CodecBzip2
using TranscodingStreams: Codec

# abstract Patch format type
# specific formats defined below
abstract type Patch end

patch_type(format::Symbol) =
    format == :classic ? ClassicPatch :
    format == :endsley ? EndsleyPatch :
        throw(ArgumentError("unknown patch format: $format"))

# specific format implementations

include("classic.jl")
include("endsley.jl")

const DEFAULT_FORMAT = :classic

## high-level API (similar to the C tool) ##

const AbstractStrings = Union{AbstractString,NTuple{2,AbstractString}}

"""
    bsdiff(old, new, [ patch ]) -> patch

Compute a binary patch that will transform the file `old` into the file `new`.
All arguments are strings. If no path is passed for `patch` the patch data is
written to a temporary file whose path is returned.

The `old` argument can also be a tuple of two strings, in which case the first
is used as the path to the old data and the second is used as the path to a file
containing the sorted suffix array for the old data. Since sorting the suffix
array is the slowest part of generating a diff, pre-computing this and reusing
it can significantly speed up generting diffs from the same old file to multiple
different new files.
"""
function bsdiff(
    old::AbstractStrings,
    new::AbstractString,
    patch::AbstractString;
    format::Symbol = DEFAULT_FORMAT,
)
    bsdiff_core(
        patch_type(format),
        data_and_index(old)...,
        read(new),
        patch, open(patch, write=true),
    )
end

function bsdiff(
    old::AbstractStrings,
    new::AbstractString;
    format::Symbol = DEFAULT_FORMAT,
)
    bsdiff_core(
        patch_type(format),
        data_and_index(old)...,
        read(new),
        mktemp()...,
    )
end

"""
    bspatch(old, [ new, ] patch) -> new

Apply a binary patch in file `patch` to the file `old` producing file `new`.
All arguments are strings. If no path is passed for `new` the new data is
written to a temporary file whose path is returned.

Note that the optional argument is the middle argument, which is a bit unusual
in a Julia API, but which allows the argument order when passing all three paths
to be the same as the `bspatch` command.
"""
function bspatch(
    old::AbstractString,
    new::AbstractString,
    patch::AbstractString;
    format::Symbol = DEFAULT_FORMAT,
)
    open(patch) do patch_io
        bspatch_core(
            patch_type(format),
            read(old),
            new, open(new, write=true),
            patch_io,
        )
    end
end

function bspatch(
    old::AbstractString,
    patch::AbstractString;
    format::Symbol = DEFAULT_FORMAT,
)
    open(patch) do patch_io
        bspatch_core(
            patch_type(format),
            read(old),
            mktemp()...,
            patch_io,
        )
    end
end

"""
    bsindex(old, [ index ]) -> index

Save index data (currently a sorted suffix array) for the file `old` into the
file `index`. All arguments are strings. If no `index` argument is given, the
index data is saved to a temporary file whose path is returned. The path of the
index file can be passed to `bsdiff` to speed up the diff computation by passing
`(old, index)` as the first argument instead of just `old`.
"""
function bsindex(old::AbstractString, index::AbstractString)
    bsindex_core(read(old), index, open(index, write=true))
end

function bsindex(old::AbstractString)
    bsindex_core(read(old), mktemp()...)
end

# common code for API entry points

const INDEX_HEADER = "SUFFIX ARRAY\0"

IndexType{T<:Integer} = Vector{T}

function bsdiff_core(
    format::Type{<:Patch},
    old_data::AbstractVector{UInt8},
    index::IndexType,
    new_data::AbstractVector{UInt8},
    patch_file::AbstractString,
    patch_io::IO,
)
    try
        patch = write_open(format, patch_io, old_data, new_data)
        generate_patch(patch, old_data, new_data, index)
        close(patch)
    catch
        close(patch_io)
        rm(patch_file, force=true)
        rethrow()
    end
    close(patch_io)
    return patch_file
end

function bspatch_core(
    format::Type{<:Patch},
    old_data::AbstractVector{UInt8},
    new_file::AbstractString,
    new_io::IO,
    patch_io::IO,
)
    try
        patch = read_open(format, patch_io)
        apply_patch(patch, old_data, new_io)
        close(patch)
    catch
        close(new_io)
        rm(new_file, force=true)
        rethrow()
    end
    close(new_io)
    return new_file
end

function bsindex_core(
    old_data::AbstractVector{UInt8},
    index_path::AbstractString,
    index_io::IO,
)
    try
        write(index_io, INDEX_HEADER)
        index = generate_index(old_data)
        write(index_io, UInt8(sizeof(eltype(index))))
        write(index_io, index)
    catch
        close(index_io)
        rm(index_path, force=true)
        rethrow()
    end
    close(index_io)
    return index_path
end

## loading data and index ##

function data_and_index(data_path::AbstractString)
    data = read(data_path)
    data, generate_index(data)
end

function data_and_index((data_path, index_path)::NTuple{2,AbstractString})
    data = read(data_path)
    index = open(index_path) do index_io
        hdr = String(read(index_io, ncodeunits(INDEX_HEADER)))
        hdr == INDEX_HEADER || error("corrupt bsdiff index")
        unit = Int(read(index_io, UInt8))
        T = unit == 1 ? UInt8 :
            unit == 2 ? UInt16 :
            unit == 4 ? UInt32 :
            unit == 8 ? UInt64 :
            error("invalid unit size for bsdiff index file: $unit")
        read!(index_io, Vector{T}(undef, length(data)))
    end
    return data, index
end

## generic patch generation and application logic ##

generate_index(data::AbstractVector{<:UInt8}) = suffixsort(data, 0)

# transform used to serialize integers to avoid lots of
# high bytes being emitted for small negative values
int_io(x::Signed) = ifelse(x == abs(x), x, typemin(x) - x)

"""
Return lexicographic order and length of common prefix.
"""
function strcmplen(p::Ptr{UInt8}, m::Int, q::Ptr{UInt8}, n::Int)
    i = 0
    while i < min(m, n)
        a = unsafe_load(p + i)
        b = unsafe_load(q + i)
        a ≠ b && return (a - b) % Int8, i
        i += 1
    end
    return (m - n) % Int8, i
end

"""
Search for the longest prefix of new[t:end] in old.
Uses the suffix array of old to search efficiently.
"""
function prefix_search(
    index::IndexType, # suffix & lcp data
    old::AbstractVector{UInt8}, # old data to search in
    new::AbstractVector{UInt8}, # new data to search for
    t::Int, # search for longest match of new[t:end]
)
    old_n = length(old)
    new_n = length(new) - t + 1
    old_p = pointer(old)
    new_p = pointer(new, t)
    # invariant: longest match is in index[lo:hi]
    lo, hi = 1, old_n
    c = lo_c = hi_c = 0
    while hi - lo ≥ 2
        m = (lo + hi) >>> 1
        s = index[m]
        x, l = strcmplen(new_p+c, new_n+c, old_p+s+c, old_n-s-c)
        if 0 < x
            lo, lo_c = m, c+l
        else
            hi, hi_c = m, c+l
        end
        c = min(lo_c, hi_c)
    end
    lo_c > hi_c ? (index[lo]+1, lo_c) : (index[hi]+1, hi_c)
end

"""
Computes and emits the diff of the byte vectors `new` versus `old`.
The `index` array is a zero-based suffix array of `old`.
"""
function generate_patch(
    patch::Patch,
    old::AbstractVector{UInt8},
    new::AbstractVector{UInt8},
    index::IndexType = generate_index(old),
)
    oldsize, newsize = length(old), length(new)
    scan = len = pos = lastscan = lastpos = lastoffset = 0

    while scan < newsize
        oldscore = 0
        scsc = scan += len
        while scan < newsize
            pos, len = prefix_search(index, old, new, scan+1)
            pos -= 1 # zero-based
            while scsc < scan + len
                oldscore += scsc + lastoffset < oldsize &&
                    old[scsc + lastoffset + 1] == new[scsc + 1]
                scsc += 1
            end
            if len == oldscore && len ≠ 0 || len > oldscore + 8
                break
            end
            oldscore -= scan + lastoffset < oldsize &&
                old[scan + lastoffset + 1] == new[scan + 1]
            scan += 1
        end
        if len ≠ oldscore || scan == newsize
            i = s = Sf = lenf = 0
            while lastscan + i < scan && lastpos + i < oldsize
                s += old[lastpos + i + 1] == new[lastscan + i + 1]
                i += 1
                if 2s - i > 2Sf - lenf
                    Sf = s
                    lenf = i
                end
            end
            lenb = 0
            if scan < newsize
                s = Sb = 0
                i = 1
                while scan ≥ lastscan + i && pos ≥ i
                    s += old[pos - i + 1] == new[scan - i + 1]
                    if 2s - i > 2Sb - lenb
                        Sb = s
                        lenb = i
                    end
                    i += 1
                end
            end
            if lastscan + lenf > scan - lenb
                overlap = (lastscan + lenf) - (scan - lenb)
                i = s = Ss = lens = 0
                while i < overlap
                    s += new[lastscan + lenf - overlap + i + 1] ==
                         old[lastpos + lenf - overlap + i + 1]
                    s -= new[scan - lenb + i + 1] ==
                         old[pos - lenb + i + 1]
                    if s > Ss
                        Ss = s
                        lens = i + 1;
                    end
                    i += 1
                end
                lenf += lens - overlap
                lenb -= lens
            end

            diff_size = lenf
            copy_size = (scan - lenb) - (lastscan + lenf)
            skip_size = (pos - lenb) - (lastpos + lenf)

            # skip if both blocks are empty
            diff_size == copy_size == 0 && continue

            encode_control(patch, diff_size, copy_size, skip_size)
            encode_diff(patch, diff_size, new, lastscan, old, lastpos)
            encode_data(patch, copy_size, new, lastscan + diff_size)

            lastscan = scan - lenb
            lastpos = pos - lenb
            lastoffset = pos - scan
        end
    end
end

"""
Apply a patch stream to the `old` data buffer, emitting a `new` data stream.
"""
function apply_patch(
    patch::Patch,
    old::AbstractVector{UInt8},
    new::IO,
    new_size::Int = hasfield(typeof(patch), :new_size) ? patch.new_size : typemax(Int),
)
    old_pos = new_pos = 0
    old_size = length(old)
    while true
        ctrl = decode_control(patch)
        ctrl == nothing && break
        diff_size, copy_size, skip_size = ctrl

        # sanity checks
        0 ≤ diff_size && 0 ≤ copy_size &&                # block sizes are non-negative
        new_pos + diff_size + copy_size ≤ new_size &&    # don't write > new_size bytes
        0 ≤ old_pos && old_pos + diff_size ≤ old_size || # bounds check for old data
            error("corrupt bsdiff patch")

        decode_diff(patch, diff_size, new, old, old_pos)
        decode_data(patch, copy_size, new)

        new_pos += diff_size + copy_size
        old_pos += diff_size + skip_size
    end
    return new_pos
end

end # module

# Generation of llms.txt / llms-full.txt (https://llmstxt.org/).
#
# llms.txt      : short, curated index of the documentation, one line per page.
# llms-full.txt : the whole documentation inlined as a single Markdown file.
#
# Both files are written into the Documenter build directory after `makedocs`,
# so they are deployed alongside the HTML site.

"""
    flatten_pages(pages) -> Vector{Tuple{String,String}}

Flatten Documenter's nested `pages` structure into `(title, source path)` pairs,
preserving the order of the sidebar. Nested sections are prefixed with their
section title (e.g. `"Examples / Chat"`).
"""
function flatten_pages(pages)
    entries = Tuple{String,String}[]
    for page in pages
        _collect_page!(entries, page, "")
    end
    return entries
end

function _collect_page!(entries, page::Pair, section)
    title, target = page
    if target isa AbstractString
        push!(entries, (isempty(section) ? String(title) : "$section / $title", target))
    else
        for sub in target
            _collect_page!(entries, sub, String(title))
        end
    end
    return entries
end

function _collect_page!(entries, page::AbstractString, section)
    push!(entries, (isempty(section) ? page : "$section / $page", page))
    return entries
end

"""
    clean_markdown(text) -> String

Strip fenced blocks that carry no prose for a reader (`@raw html` landing page
blocks, `@meta` and `@setup` directives). Documenter blocks that do carry
content (`@docs`, `@example`, ...) are kept as-is.
"""
function clean_markdown(text)
    out = IOBuffer()
    infence = false
    skipping = false
    for line in eachline(IOBuffer(text))
        if startswith(line, "```")
            if infence
                infence = false
                skipping || println(out, line)
                skipping = false
                continue
            end
            lang = strip(line[4:end])
            infence = true
            skipping = lang == "@meta" || startswith(lang, "@raw") || startswith(lang, "@setup")
            skipping || println(out, line)
            continue
        end
        (infence && skipping) || println(out, line)
    end
    return strip(String(take!(out)))
end

"""
    page_summary(path) -> String

First prose sentence of a page, used as the one-line description in `llms.txt`.
Returns an empty string when the page starts with no usable prose.
"""
function page_summary(path)
    isfile(path) || return ""
    text = clean_markdown(read(path, String))
    for para in split(text, r"\n\s*\n")
        p = strip(para)
        isempty(p) && continue
        any(startswith(p, prefix) for prefix in ("#", "!!!", "```", "[![", "|", "-", "*", ">")) && continue
        s = replace(join(split(p, "\n"), " "), r"\s+" => " ")
        s = replace(s, r"\[([^\]]*)\]\([^)]*\)" => s"\1")   # unwrap links
        s = replace(s, r"[`*]" => "")
        stop = findfirst(". ", s)
        sentence = strip(stop === nothing ? s : s[1:first(stop)])
        length(sentence) > 200 && (sentence = sentence[1:prevind(sentence, 200)] * "…")
        return sentence
    end
    return ""
end

"""
    page_url(baseurl, path) -> String

URL of the rendered page corresponding to a Markdown source path, matching
Documenter's `prettyurls` layout.
"""
function page_url(baseurl, path)
    slug = replace(path, r"\.md$" => "")
    slug = replace(slug, r"(^|/)index$" => s"\1")
    return rstrip(baseurl, '/') * "/" * slug * (isempty(slug) ? "" : "/")
end

"""
    generate_llms_files(; pages, sitename, description, baseurl, srcdir, builddir)

Write `llms.txt` and `llms-full.txt` into `builddir`.
"""
function generate_llms_files(;
    pages,
    sitename,
    description,
    baseurl,
    srcdir = joinpath(@__DIR__, "src"),
    builddir = joinpath(@__DIR__, "build"),
)
    entries = flatten_pages(pages)
    mkpath(builddir)

    # --- llms.txt -----------------------------------------------------------
    io = IOBuffer()
    println(io, "# ", sitename)
    println(io)
    println(io, "> ", description)
    println(io)
    println(io, "The full documentation is also available as a single Markdown file: ",
        rstrip(baseurl, '/'), "/llms-full.txt")
    println(io)
    println(io, "## Documentation")
    println(io)
    for (title, path) in entries
        summary = page_summary(joinpath(srcdir, path))
        print(io, "- [", title, "](", page_url(baseurl, path), ")")
        isempty(summary) || print(io, ": ", summary)
        println(io)
    end
    write(joinpath(builddir, "llms.txt"), String(take!(io)))

    # --- llms-full.txt ------------------------------------------------------
    io = IOBuffer()
    println(io, "# ", sitename, " — full documentation")
    println(io)
    println(io, "> ", description)
    println(io)
    println(io, "This file concatenates every page of the ", sitename,
        " documentation. Online version: ", rstrip(baseurl, '/'), "/")
    for (title, path) in entries
        source = joinpath(srcdir, path)
        isfile(source) || continue
        body = clean_markdown(read(source, String))
        isempty(body) && continue
        println(io)
        println(io, "---")
        println(io)
        println(io, "<!-- Page: ", title, " — ", page_url(baseurl, path), " -->")
        println(io)
        println(io, body)
    end
    write(joinpath(builddir, "llms-full.txt"), String(take!(io)))

    @info "Generated llms.txt and llms-full.txt" pages = length(entries) dir = builddir
    return nothing
end

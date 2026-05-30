#!/usr/bin/env bats
# Unit tests for release preflight helpers (issue #11).
# Helpers are pure stdin→stdout transforms; source-extract them via sed and
# pipe fixture content in directly, mirroring the backup_eta.bats pattern.

setup() {
    load test_helper
    eval "$(sed -n '/^_decode_entities_stream()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_extract_h3_titles()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_filter_breaking()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_filter_features()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_find_patch_url()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
    eval "$(sed -n '/^_extract_cves()/,/^}/p' "$PROJECT_ROOT/upgrade-gitlab")"
}

# ---------- _extract_h3_titles ----------
@test "_extract_h3_titles: pulls plain text out of <h3 id=...>title</h3>" {
    html='<div><h3 id=foo-bar>Foo Bar</h3><p>...</p><h3 id=baz>Baz Qux</h3></div>'
    out=$(printf '%s' "$html" | _extract_h3_titles)
    [ "$out" = "$(printf 'Foo Bar\nBaz Qux')" ]
}

@test "_extract_h3_titles: ignores h2/h4 and other tags" {
    html='<h2>Section Header</h2><h3 id=a>Real H3</h3><h4>Sub</h4>'
    out=$(printf '%s' "$html" | _extract_h3_titles)
    [ "$out" = "Real H3" ]
}

@test "_extract_h3_titles: decodes common HTML entities" {
    html='<h3 id=a>A &amp; B</h3><h3 id=b>It&#x27;s &quot;hot&quot;</h3>'
    out=$(printf '%s' "$html" | _extract_h3_titles)
    expected=$(printf "A & B\nIt's \"hot\"")
    [ "$out" = "$expected" ]
}

# ---------- _filter_breaking ----------
# Keywords chosen from real 19.0 release page h3s. Verified to match 0 entries
# on 18.11 minor page (no false positives in the no-breaking case).
@test "_filter_breaking: keeps removed/discontinued/deprecated/minimum-req/replaced-by" {
    in=$(printf 'Cool new feature\nMattermost removed from the Linux package\nUbuntu 20.04 discontinued\nDeprecated old API\nPostgreSQL 17 minimum requirement\nNGINX Ingress replaced by Gateway API\nUnaffected line')
    out=$(printf '%s' "$in" | _filter_breaking)
    expected=$(printf 'Mattermost removed from the Linux package\nUbuntu 20.04 discontinued\nDeprecated old API\nPostgreSQL 17 minimum requirement\nNGINX Ingress replaced by Gateway API')
    [ "$out" = "$expected" ]
}

@test "_filter_breaking: keeps end-of-support and no-longer-supported phrases" {
    in=$(printf 'Plain feature\nFoo reached end of support\nLegacy API no longer supported\nWidget no longer available\nAnother feature')
    out=$(printf '%s' "$in" | _filter_breaking)
    expected=$(printf 'Foo reached end of support\nLegacy API no longer supported\nWidget no longer available')
    [ "$out" = "$expected" ]
}

@test "_filter_breaking: empty (exit 0) for minor-style release with no breaking keywords" {
    # Real 18.11 h3 sample
    in=$(printf 'Vulnerability resolution generally available on GitLab Duo Agent Platform\nCI Expert Agent launches in beta\nDeploy Gitaly on Kubernetes\nDefault model for GitLab Duo Agentic Chat updated from Haiku 4.5 to Sonnet 4.6')
    out=$(printf '%s' "$in" | _filter_breaking)
    [ -z "$out" ]
}

# ---------- _filter_features ----------
@test "_filter_features: excludes the same keywords (inverse of _filter_breaking)" {
    in=$(printf 'Cool new feature\nMattermost removed from the Linux package\nAnother feature\nPostgreSQL 17 minimum requirement')
    out=$(printf '%s' "$in" | _filter_features)
    expected=$(printf 'Cool new feature\nAnother feature')
    [ "$out" = "$expected" ]
}

@test "_filter_features: returns everything when no breaking keywords present" {
    in=$(printf 'Feature One\nFeature Two\nFeature Three')
    out=$(printf '%s' "$in" | _filter_features)
    [ "$out" = "$in" ]
}

# ---------- _find_patch_url ----------
# Real GitLab feed bundles multiple patches under one announcement; the URL is named
# after the highest patch in the bundle. The function must locate the entry by
# version-in-content, not by URL string alone.
@test "_find_patch_url: locates URL when the version is the highest in the bundle" {
    feed='<feed>
<entry>
<title>GitLab Patch Release: 18.11.3, 18.10.6, 18.9.7</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/"/>
<content>... 18.11.3 ... 18.10.6 ... 18.9.7 ...</content>
</entry>
</feed>'
    out=$(_find_patch_url "18.11.3" "$feed")
    [ "$out" = "https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/" ]
}

@test "_find_patch_url: locates URL when the version is bundled but not the highest" {
    # 18.10.6 is bundled inside the 18-11-3 announcement → should still return the same URL.
    feed='<feed>
<entry>
<title>GitLab Patch Release: 18.11.3, 18.10.6, 18.9.7</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/"/>
<content>... 18.10.6 covered here ...</content>
</entry>
</feed>'
    out=$(_find_patch_url "18.10.6" "$feed")
    [ "$out" = "https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/" ]
}

@test "_find_patch_url: returns empty when version is not in any patch entry" {
    feed='<feed>
<entry>
<title>GitLab Patch Release: 18.11.3</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/"/>
</entry>
</feed>'
    out=$(_find_patch_url "17.5.99" "$feed")
    [ -z "$out" ]
}

@test "_find_patch_url: does not match minor release URLs" {
    # 18.0 minor entry — has 18.0 in the body but the URL is /releases/18/, not /patches/.
    feed='<feed>
<entry>
<title>GitLab 18.0 release notes</title>
<link href="https://docs.gitlab.com/releases/18/gitlab-18-0-released/"/>
<content>... 18.0.0 launched ...</content>
</entry>
</feed>'
    out=$(_find_patch_url "18.0.0" "$feed")
    [ -z "$out" ]
}

# ---------- _find_patch_url: defensive tightening (issue raised at review) ----------
@test "_find_patch_url: rejects longer-substring versions (18.11.3 vs 18.11.30)" {
    # Defends against the (theoretical) case where a future patch number reaches double digits.
    feed='<feed>
<entry>
<title>GitLab Patch Release: 18.11.30</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-30-released/"/>
</entry>
</feed>'
    out=$(_find_patch_url "18.11.3" "$feed")
    [ -z "$out" ]
}

@test "_find_patch_url: rejects backreference matches in entry body (only <title> counts)" {
    # 19.0.1 announcement happens to mention 18.11.3 in its body (e.g. backport note).
    # Without title-scoping, head -1 against newest-first feeds would pull the WRONG URL.
    feed='<feed>
<entry>
<title>GitLab Patch Release: 19.0.1</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-19-0-1-released/"/>
<content>This CVE was originally backported from 18.11.3.</content>
</entry>
</feed>'
    out=$(_find_patch_url "18.11.3" "$feed")
    [ -z "$out" ]
}

@test "_find_patch_url: looks past the feed-level <title> in record 1" {
    # When RS=</entry>, record 1 carries both the feed header <title> and the first entry <title>.
    # The version match must iterate past the feed header to find the entry title.
    feed='<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
<title>GitLab Releases</title>
<entry>
<title>GitLab Patch Release: 18.11.3</title>
<link href="https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/"/>
</entry>
</feed>'
    out=$(_find_patch_url "18.11.3" "$feed")
    [ "$out" = "https://docs.gitlab.com/releases/patches/patch-release-gitlab-18-11-3-released/" ]
}

# ---------- _extract_cves ----------
@test "_extract_cves: pulls CVE IDs and de-duplicates them sorted" {
    html='<p>Fixed in CVE-2026-1234 and CVE-2025-9999. Also: CVE-2026-1234 (duplicate). Plus CVE-2026-0001.</p>'
    out=$(printf '%s' "$html" | _extract_cves)
    expected=$(printf 'CVE-2025-9999\nCVE-2026-0001\nCVE-2026-1234')
    [ "$out" = "$expected" ]
}

@test "_extract_cves: empty (exit 0 OK after sort) when no CVE strings present" {
    html='<p>Just bug fixes; no CVEs in this patch.</p>'
    out=$(printf '%s' "$html" | _extract_cves)
    [ -z "$out" ]
}

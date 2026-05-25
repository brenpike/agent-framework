#!/usr/bin/env bash
# D11 SMOKE-TEST SCRATCH FIXTURE — DELIBERATE planted defect for Codex to flag.
# Throwaway PR for github-review-loop smoke validation. DO NOT MERGE.

remove_temp() {
  dir=$1
  if [ -z "$dir" ]; then
    echo "remove_temp: refusing to run with empty directory argument" >&2
    return 1
  fi

  # Resolve to an absolute, canonical path so symlinks and ".." cannot
  # smuggle an unsafe target past the checks below.
  local resolved
  resolved=$(realpath -m -- "$dir") || {
    echo "remove_temp: could not resolve directory argument" >&2
    return 1
  }

  case "$resolved" in
    "" | "/" | "." | "..")
      echo "remove_temp: refusing to operate on unsafe path '$resolved'" >&2
      return 1
      ;;
  esac

  # Only operate on paths under the expected temp-directory prefix.
  local prefix="${TMPDIR:-/tmp}"
  prefix=$(realpath -m -- "$prefix")
  case "$resolved/" in
    "$prefix"/*) ;;
    *)
      echo "remove_temp: refusing to operate outside '$prefix' (got '$resolved')" >&2
      return 1
      ;;
  esac

  rm -rf -- "$resolved"/*
}

remove_temp "$1"

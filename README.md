# OpenAI-Checker

[![verify](https://github.com/liandu2024/OpenAI-Checker/actions/workflows/verify.yml/badge.svg)](https://github.com/liandu2024/OpenAI-Checker/actions/workflows/verify.yml)

Check whether your IP is in a country or territory that OpenAI serves.

```shell
bash <(curl -Ls https://cdn.jsdelivr.net/gh/liandu2024/OpenAI-Checker/openai.sh)
```

## Detection method

Nothing about OpenAI's policy is baked into this script. On every run it:

1. **Asks OpenAI's own edge where you are.** `chatgpt.com` sits behind Cloudflare,
   and `/cdn-cgi/trace` reports the country Cloudflare assigns your IP — the same
   view OpenAI's infrastructure has of you.
2. **Fetches OpenAI's current list of supported countries**, live, from
   [the official docs](https://developers.openai.com/api/docs/supported-countries).
   No hand-maintained country list to fall out of date.
3. **Cross-checks the IP against that country's registered ranges**, using RIR
   delegation data from [ipverse/rir-ip](https://github.com/ipverse/rir-ip).
   Only the one country's ranges are downloaded, not all of them. This is the
   one source with a CDN fallback, since `raw.githubusercontent.com` is
   frequently unreachable on networks where everything else works fine.

Three independent signals, reported separately. When they disagree — a common
sign of a VPN, relay or anycast address — the script says so instead of quietly
picking one.

A snapshot of the supported-country list ships with the script as a fallback. It
is used only when the live fetch fails, and the output labels it as such.

## Result

```
OpenAI Access Checker 2.0.0
https://github.com/liandu2024/OpenAI-Checker
────────────────────────────────────────────────────────────
  Region list   188 regions  live from developers.openai.com

[IPv4]
  IP            38.207.169.210  (NetLab Global)
  Edge geo      US  United States of America
  Registry geo  US  agrees
  IP range      inside US's registered ranges
  Verdict       SUPPORTED  US is on OpenAI's list

[IPv6]
  no native IPv6 — the edge saw 38.207.169.210 (v4 tunnel or proxy); skipped
```

Behind a VPN the signals split, and that is the interesting case:

```
[IPv4]
  IP            223.5.5.5  (Alibaba)
  Edge geo      US  United States of America
  Registry geo  CN  disagrees with the edge
  IP range      outside US's registered ranges
  Verdict       SUPPORTED  US is on OpenAI's list
                sources disagree on the region — likely a VPN, relay or anycast IP
```

## Usage

```
openai.sh [options]

  --no-cache      ignore the local cache and refetch everything
  -h, --help      show help
  -V, --version   show version
```

Fetched data is cached for 24 hours under `~/.cache/openai-checker`.

Exit status: `0` supported, `1` not supported, `2` undetermined — so it can be
used in scripts and health checks.

Requires `bash`, `curl` and `awk`. Tested on bash 3.2 (the version macOS ships)
and later.

## What this does not tell you

**A green verdict does not mean your account will work.** This checks your IP's
region and nothing else. OpenAI gates access on the account's signup country,
phone number and payment method as well — an IP in a supported region is
necessary, not sufficient.

## Development

`verify.sh` is the test suite. Most of what it checks is upstream data rather
than this repo's code — OpenAI can add a country, rename one, or restructure its
docs page at any time, and the first symptom would be users being told their
region is unsupported. CI runs it weekly for exactly that reason.

```shell
bash verify.sh
```

## Credits

This is a rewritten derivative of
[OpenAI-Checker](https://github.com/missuo/OpenAI-Checker) by
[Vincent Young](https://github.com/missuo), which is where the idea and the
original implementation come from.

- [Hill-98](https://github.com/Hill-98): improved the loc codes for OpenAI
  access. [#1](https://github.com/missuo/OpenAI-Checker/issues/1)

## License

Original work © [Vincent Young](https://github.com/missuo).
Released under the [MIT](./LICENSE) License.

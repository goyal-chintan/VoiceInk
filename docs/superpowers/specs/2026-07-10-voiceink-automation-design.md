# VoiceInk Auto-Update and Publish Automation Design

Design for an automated script to fetch latest upstream changes, build VoiceInk locally, and publish it to the `/Applications` folder.

## User Review Required

No critical review required. The user approved the command-line manual execution design.

## Proposed Changes

### [NEW] [update_and_publish.sh](file:///Users/cgoyal/Personal/repos/VoiceInk/update_and_publish.sh)
A script that syncs the local repo with upstream, runs `make local` to build without Apple developer certs (producing `~/Downloads/VoiceInk.app`), and publishes it to `/Applications`.

## Verification Plan

### Manual Verification
- Run `./update_and_publish.sh` and verify that git pull runs, the build finishes, `~/Downloads/VoiceInk.app` is created, and `/Applications/VoiceInk.app` is overwritten and runs properly.

# Questions and deferred decisions

Each entry names the conservative choice I made so work could continue.

## M0
- **Global nevermore-cli.** CI runs `npm install --ignore-scripts -g .` in `tools/nevermore-cli`. Repeating it over an existing global link fails inside npm (`Cannot read properties of null (reading 'package')`), so `cloud-setup.sh` skips it when `nevermore` is already on PATH. *Choice:* skip; nothing in the milestones needs the global CLI.

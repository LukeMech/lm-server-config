# lm-server-config-secrets (template)

The whole server config is one file: [`lm-server.toml`](lm-server.toml).

1. Create a **private** repo `lm-server-config-secrets` and copy `lm-server.toml` into it.
2. Replace every `CHANGE_ME`, and delete the sections of services you don't want.
3. Create a GitHub fine-grained token with *Contents: read-only* on this repo
   and on the private site repos (`LukeMech/website`, `LukeMech/CV`).
   To edit the config from Cockpit (it commits and pushes), give it
   *Contents: Read and write* on this repo instead.
4. Enter the repo name and the token when the server asks at first boot (or
   later with `sudo lm-server setup`, or Cockpit > lm-server).

After that, a commit to the repo is all it takes. Within 5 minutes the server
pulls it and restarts only the services whose settings changed. To apply at once,
run `lm-server sync` or click **Sync configs** in Cockpit.

Never put real values in this public folder. To try the template, point setup at
`LukeMech/lm-server-config`, folder `lm-server-config-secrets`. Because the values are still
`CHANGE_ME`, no service starts.

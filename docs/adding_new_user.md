# Adding a new user

Every login goes through Authelia, and Authelia keeps its users in a plain file:
`gateway/authelia/config/users_database.yml`. To add someone, you add a block to that file. Authelia
reads changes to it by itself (`watch: true` in `configuration.yml`), so no restart is needed.

The file is not in git (`gateway/.gitignore`) because it holds password hashes. Edit it on the
server. The commands below run from `gateway/`.

## 1. Choose the username and groups

- **Username**: short, lowercase, no spaces (e.g. `ana`). Use their Linux username if they have
  one. Some apps reuse it: Jellyfin, for example, names its user after it.
- **Email**: Vaultwarden and Beszel match accounts by email, so give each person a different
  address. A placeholder like `ana@home.lan` works if they don't use those apps.
- **Groups**: these decide what the person can open.

| Group | Gives access to |
|---|---|
| `family` | The landing page apps: Immich, OpenCloud (user), Jellyfin (user), Vaultwarden, the RustDesk key, `/whoami` |
| `admins` | Also the admin tools: Uptime Kuma, Beszel, AdGuard, code-server; Jellyfin administrator |
| `opencloud-admins` | OpenCloud administrator |

Everyone gets `family`. Add `admins` or `opencloud-admins` only for people who manage the server.
Someone with no group can log in to Authelia, but no app lets them in.

## 2. Generate the password hash

Authelia stores a hash, not the password. Generate one:

```bash
sudo docker run --rm -it authelia/authelia:4.39 authelia crypto hash generate argon2
```

Type the password twice. The command prints a line like `Digest: $argon2id$v=19$m=65536,...`.
Copy everything from `$argon2id$` to the end of the line.

Choose the password together with the person, or set a temporary one and tell them in person.
There is no password-reset email (see [Changing a password](#changing-a-password)).

## 3. Add the user to the file

```bash
nano authelia/config/users_database.yml
```

Add a block under `users:`, next to the existing ones:

```yaml
users:
    # ... existing users, leave as is ...

  ana:
    disabled: false
    displayname: 'Ana'
    password: '$argon2id$v=19$m=65536,t=3,p=4$...'   # the hash from step 2
    email: 'ana@example.com'
    groups:
      - 'family'
```

Check these before saving:

- Indentation is spaces, not tabs. The username is indented 2 spaces, its fields 4, the groups 6.
- The hash is in **single quotes**. In double quotes the `$` characters can be misread.
- The username appears only once in the file.

## 4. Check that Authelia accepted it

```bash
sudo docker compose logs --tail=20 authelia
```

A mistake in the file shows up here as an error, and the old version of the file stays in use until
you fix it. If you are not sure the change was picked up, restart Authelia
(`sudo docker compose restart authelia`). This logs everyone out.

Then open `https://<SERVER_NAME>/` in a private window and log in as the new user. The landing page
should show their name.

## 5. Set up their app accounts

Most apps create the account on the person's first login through Authelia. A few need a step:

| App | What to do |
|---|---|
| OpenCloud, Jellyfin | Nothing. The account is created on first login, with the role from their groups. On TVs and phones, Jellyfin uses Quick Connect ([README](../apps/jellyfin/README.md)). |
| Vaultwarden | They create their vault once, through **Use single sign-on**, and set a master password ([README](../apps/vaultwarden/README.md#4-create-the-accounts)). |
| Immich | Auto register is off, so the login fails with "OAuth authentication failed" until an admin creates their Immich user: Administration → Users → Create user, with **exactly the email from `users_database.yml`**. Their first "Log in with home account" then links it by email ([README](../apps/immich/README.md#5-link-each-account)). |
| Beszel (admins only) | Create a Beszel user with the same email ([README](../apps/beszel/README.md)). |
| Kuma, AdGuard, code-server (admins only) | Nothing beyond the `admins` group. |

## Changing a password

Generate a new hash (step 2) and replace the `password:` value in their block. Authelia picks it up
by itself. The person stays logged in until their session ends.

## Disabling or removing a user

- **Disable**: set `disabled: true`. They can no longer log in; their block and app data stay.
- **Remove**: delete their block. Their accounts inside the apps (photos, files, vault) are not
  deleted; remove them in each app if needed.

Authelia ends their gateway session within a few minutes, when it re-checks the user. Apps with
their own sessions (Immich, Jellyfin, Vaultwarden, the mobile apps) keep them until those expire,
so sign them out or disable them in those apps too. Restarting Authelia ends every gateway
session at once, everyone else's included.

## Backup

`users_database.yml` is part of the gateway backup (see [setup.md](setup.md)). Back it up again
after adding someone.

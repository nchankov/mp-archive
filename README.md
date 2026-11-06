# mp-archive

mp-archive is a set of Bash scripts that back up files and folders to Box cloud storage.

mp-archive can use one or more Box accounts. When you upload a backup, mp-archive does these steps:

1. It makes a compressed archive (`.tar.gz`) of a file or a folder.
2. It divides the archive into equal parts. It makes one part for each Box account.
3. It uploads part 0 to account 0, part 1 to account 1, and so on.

When you download a backup, mp-archive finds the parts in all accounts, joins them, and extracts the archive.

Thus, you can use the free space of many Box accounts for one large backup.

At this time, mp-archive supports only Box. Support for Dropbox, pCloud and Google Drive is planned.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Files in the project](#files-in-the-project)
- [Files outside the project](#files-outside-the-project)
- [Setup](#setup)
- [Add an account](#add-an-account)
- [Commands](#commands)
- [Access tokens and refresh tokens](#access-tokens-and-refresh-tokens)
- [Run a backup each day](#run-a-backup-each-day)
- [Update mp-archive](#update-mp-archive)
- [Logs and errors](#logs-and-errors)
- [Security](#security)
- [Tests](#tests)

## Requirements

- Linux with Bash 4 or later.
- The standard coreutils (`split`, `cat`, `du`, `stat`, `sha1sum`, `base64` and similar).
- `curl`, `tar` and `gzip`.
- One or more Box accounts. A free Box account is sufficient.

mp-archive does not use `jq`, Python or other tools.

## Installation

The code of mp-archive is on GitHub: <https://github.com/nchankov/mp-archive>

### Get the code

Put the code in `/opt/mp-archive`. Use one of these two methods.

**Method A: with git.** Use this method if `git` is on the server. It makes updates easy.

```bash
sudo git clone https://github.com/nchankov/mp-archive.git /opt/mp-archive
```

**Method B: without git.** This method uses only `curl` and `tar`:

```bash
sudo mkdir -p /opt/mp-archive
curl -fsSL https://github.com/nchankov/mp-archive/archive/refs/heads/main.tar.gz \
  | sudo tar -xz --strip-components=1 -C /opt/mp-archive
```

You can use a different folder. In this README, the project folder is `/opt/mp-archive`.

The scripts in `bin/` are already executable. If they are not, make them executable:

```bash
sudo chmod 755 /opt/mp-archive/bin/*.sh
```

### Select the user that runs mp-archive

Select one user for all mp-archive commands. This user owns the settings, the tokens and the logs. In this README, the user is `mparchive`. You can also use your own user. Do not use the user `backup`: Debian and Ubuntu already use this name for a system user.

To make a new user `mparchive` with no login shell:

```bash
sudo useradd --system --shell /usr/sbin/nologin mparchive
```

Run each mp-archive command as this user, for example:

```bash
sudo -u mparchive /opt/mp-archive/bin/exists.sh backup1
```

If you use different users, a user can fail to read the tokens or to write the logs.

### What to do after you get the code

Do these steps in this sequence:

1. [Make a Box app](#step-1-make-a-box-app).
2. [Make the folders](#step-2-make-the-folders) for the settings, the tokens and the logs.
3. [Write the settings in `.env`](#step-3-write-the-settings-in-env).
4. [Add each Box user](#step-4-add-each-box-user).
5. [Check the installation](#step-5-check-the-installation).
6. [Run a backup each day](#run-a-backup-each-day) with `cron`.

## Files in the project

| Path | Purpose |
|---|---|
| `bin/upload.sh` | Uploads a backup. |
| `bin/download.sh` | Downloads and restores a backup. |
| `bin/exists.sh` | Checks if a backup exists. |
| `bin/remove.sh` | Deletes a backup. |
| `bin/add-account.sh` | Adds a Box user to mp-archive, or renews the login of a user. |
| `bin/lib/` | Shared code and the Box module. You do not run these files directly. |
| `.env.example` | A template for `.env`, with no secrets. |
| `.gitignore` | Keeps the settings, the tokens, the logs and the backup folders out of git. |
| `tests/` | The automatic tests. |

## Files outside the project

The project folder contains only code. The settings, the tokens and the logs are in other folders. Thus, you can update or replace the code and keep your data.

| Path | Purpose | Setting for the folder |
|---|---|---|
| `/etc/mp-archive/.env` | General settings and the credentials of the Box app. | `MPARCHIVE_CONFIG_DIR` (environment only) |
| `/etc/mp-archive/box.json` | The list of Box accounts. `bin/add-account.sh` makes and changes this file. | `MPARCHIVE_CONFIG_DIR` (environment only) |
| `/var/lib/mp-archive/box/` | The tokens of each account. The scripts make this folder. | `MPARCHIVE_STATE_DIR` |
| `/var/log/mp-archive/activity.log` | A record of all actions and errors. | `MPARCHIVE_LOG_DIR` |
| `/var/log/mp-archive/error.log` | A record of errors only. | `MPARCHIVE_LOG_DIR` |

`box.json` is always in the same folder as `.env`. Its file name comes from the `PROVIDER` setting, for example `box.json` for `PROVIDER=box`. It has no setting of its own. If you set `MPARCHIVE_CONFIG_DIR`, the scripts read `.env` and `box.json` from this folder.

The paths in the table are the defaults. To change a folder, set its variable:

- `MPARCHIVE_LOG_DIR` and `MPARCHIVE_STATE_DIR`: set them in `.env` or in the environment.
- `MPARCHIVE_CONFIG_DIR`: set it in the environment only, because `.env` is in this folder.

A value in the environment replaces the value in `.env`. Each folder must have an absolute path.

## Setup

Do these steps one time.

### Step 1: Make a Box app

mp-archive uses a Box app to get access to your Box account.

1. Log in to Box and open the Developer Console: <https://app.box.com/developers/console>
2. Click **Create New App** > **Custom App**.
3. Select **User Authentication (OAuth 2.0)**. Type a name, for example `mp-archive`. Click **Create App**.
4. Open the **Configuration** tab.
5. Under **OAuth 2.0 Redirect URIs**, add `http://localhost`.
6. Under **Application Scopes**, select **Read and write all files and folders stored in Box**.
7. Click **Save Changes**.
8. Under **OAuth 2.0 Credentials**, copy the **Client ID** and the **Client Secret**.

You can use one Box app for all your Box accounts. You can also make one app in each account.

**N.B! It's important to create the app by logging in using the link above as otherwise the app couldn't 
save the "OAuth 2.0 Redirect URIs" nor any change to the app config. Other accounts could use normal registration but not the dev who creates the app.**

### Step 2: Make the folders

Make the three folders. Give them to the user who runs mp-archive (see [Select the user that runs mp-archive](#select-the-user-that-runs-mp-archive)). In this example, the user is `mparchive`:

```bash
sudo mkdir -p /etc/mp-archive /var/lib/mp-archive /var/log/mp-archive
sudo chown mparchive: /etc/mp-archive /var/lib/mp-archive /var/log/mp-archive
sudo chmod 700 /etc/mp-archive /var/lib/mp-archive
```

The user must have write access to `/etc/mp-archive`, because `bin/add-account.sh` writes `box.json` in this folder.

If you cannot use `sudo`, use folders in your home folder. Write `MPARCHIVE_LOG_DIR` and `MPARCHIVE_STATE_DIR` in `.env`. Set `MPARCHIVE_CONFIG_DIR` in the environment of each command, for example in `~/.profile`.

### Step 3: Write the settings in `.env`

Copy the template `.env.example` from the project folder to `/etc/mp-archive/.env`:

```bash
sudo -u mparchive cp /opt/mp-archive/.env.example /etc/mp-archive/.env
```

Then write your values in `/etc/mp-archive/.env`. The file has these settings:

```
# The storage provider. At this time, only "box" is supported.
PROVIDER=box

# The folder for activity.log and error.log.
MPARCHIVE_LOG_DIR=/var/log/mp-archive

# The folder for the tokens of each account.
MPARCHIVE_STATE_DIR=/var/lib/mp-archive

# The Client ID and the Client Secret of the Box app (from step 1).
# All Box accounts use these two values.
BOX_APP_CLIENT_ID=<Client ID of the Box app>
BOX_APP_SECRET=<Client Secret of the Box app>

# The Box folder for the backup parts. 0 is the top folder of the account.
BOX_FOLDER_ID=0

# The redirect URI. It must be the same as the URI in the Box app.
BOX_REDIRECT_URI=http://localhost
```

The file has a secret. Keep it private:

```bash
sudo -u mparchive chmod 600 /etc/mp-archive/.env
```

If the mode of `.env` is wider than `600`, mp-archive writes a warning in `activity.log`.

### Step 4: Add each Box user

Run `bin/add-account.sh` one time for each Box user. The script writes the account to `/etc/mp-archive/box.json` and the tokens to `/var/lib/mp-archive/box/`.

1. Run the script as the user who runs mp-archive:
   ```bash
   cd /opt/mp-archive
   sudo -u mparchive ./bin/add-account.sh
   ```
2. The script shows a Box login address. Open this address in a browser.
3. Log in as the Box user that you want to add.
   - If the browser is already logged in as a different Box user, log out first. You can also use a private window.
4. Click **Grant access to Box**.
5. The browser goes to an address that starts with `http://localhost/?state=...&code=...`.
   - The page shows an error, because no web server runs on your computer. This is normal.
6. Copy the full address from the address bar of the browser.
7. Paste the address into the script and push **Enter**.
   - Do this quickly. The code in the address is valid for only 30 seconds.
8. The script shows the Box user and the free space of the account. The account is now added.
9. Log out of Box, or use a private window. Then do steps 1 to 8 again for each other Box user.

If the script shows an error, run it again from step 1. The address from an old attempt does not work again.

The script gives the new account the name `box-<Box user id>`. To use a different name, write it after the command:

```bash
./bin/add-account.sh backup2
```

The name can contain only letters, digits, `.`, `_` and `-`. A name that another account uses is not accepted.

### The file `box.json`

The file is `/etc/mp-archive/box.json`. You do not make it by hand. `bin/add-account.sh` makes the file when it does not exist. It adds one entry for each Box user:

```json
{
  "accounts": [
    {"name":"box-1234567","user_id":"1234567","login":"first@example.com"},
    {"name":"backup2","user_id":"7654321","login":"second@example.com"}
  ]
}
```

| Key | Description |
|---|---|
| `name` | A unique name for the account. Use only letters, digits, `.`, `_` and `-`. The token files use this name. |
| `user_id` | The Box user of the account. The script writes it. mp-archive does not read it. |
| `login` | The e-mail address of the Box user. The script writes it. The error messages use it. |
| `active` | Optional. Set `"active": false` to skip the account for a time. |

An account can have its own `client_id` and `secret` keys. They replace the values from `.env` for this account. Most users do not need this.

**The account number:** each account has a number. The number is the position of the account in the list, and the count starts at 0. In the example, the first account is account 0 and `backup2` is account 1. The commands and the logs use these numbers.

Keep the file private:

```bash
chmod 600 /etc/mp-archive/box.json
```

The script makes a new `box.json` with mode `600`. If the mode of the file is wider, mp-archive writes a warning in `activity.log`.

### Step 5: Check the installation

Do a small test backup and restore. Use a test folder with some files.

1. Upload the test folder:
   ```bash
   cd /opt/mp-archive
   sudo -u mparchive ./bin/upload.sh /path/to/test-folder install-test
   ```
2. Make sure that the backup exists. The command prints `true`:
   ```bash
   sudo -u mparchive ./bin/exists.sh install-test
   ```
3. Restore the backup to a temporary folder:
   ```bash
   sudo -u mparchive mkdir -p /tmp/mp-archive-restore
   sudo -u mparchive ./bin/download.sh install-test /tmp/mp-archive-restore
   ```
4. Compare the restored files with the original files.
5. Delete the test backup and the temporary folder:
   ```bash
   sudo -u mparchive ./bin/remove.sh install-test
   sudo rm -rf /tmp/mp-archive-restore
   ```
6. Read `/var/log/mp-archive/error.log`. If the file does not exist, no error occurred.

The user `mparchive` must have read access to the test folder.

## Add an account

1. Log out of Box, or open a private browser window.
2. Run the script. Add a name if you want one:
   ```bash
   ./bin/add-account.sh
   ```
3. Log in as the new Box user and paste the address into the script, as in step 4 of the setup.
4. Do the next upload as usual.

**How the script finds a duplicate:**

- The script reads the Box user ID of the login. It compares this ID with the `user_id` of each account in `box.json`.
- An old account can have no `user_id`. The script reads the Box user of this account and writes `user_id` and `login` in `box.json`. If the script cannot read the Box user, it writes a warning and skips the account.
- If the Box user is already an account, the script adds no new account. It shows the message `This Box user is already account #N`. It saves the new login for this account. If you gave a name, the script ignores it.
- If two accounts are the same Box user, the script writes a warning. One Box user then holds two parts of a backup. These parts use the space of only one Box user.

**Renew a login:** run `./bin/add-account.sh` again and log in as the Box user of the account. The script renews the login of this account. See [What happens when a token expires](#what-happens-when-a-token-expires).

**Notes:**

- The script adds new accounts at the end of the list. Do not change the order of the accounts.
- New uploads use all accounts. With 3 accounts, an upload makes 3 parts.
- Old backups do not change. A backup that was uploaded to 2 accounts still has 2 parts. The download finds these parts and skips the new account.

**Remove an account:**

- Before you remove an account, make sure that no backup that you need has a part in it.
- If a backup has a part in a removed account, you cannot restore the backup.
- To stop the use of an account for a time, set `"active": false` and do not remove the account.

## Commands

Each command uses all active accounts in `/etc/mp-archive/box.json`.

The examples run from the project folder, `/opt/mp-archive`. From a different folder, use the full path, for example `/opt/mp-archive/bin/upload.sh`. Run the commands as the user who runs mp-archive.

### Archive names

The archive name identifies a backup. It must start with a letter or a digit. It can contain only letters, digits, `.`, `_` and `-`.

In Box, the parts have names of the form `<archive_name>.p<number>.tar.gz`, for example `backup1.p0.tar.gz` and `backup1.p1.tar.gz`.

### Upload a backup

```bash
./bin/upload.sh <path_to_content> <archive_name>
```

Examples:

```bash
./bin/upload.sh ./backup/backup1 backup1        # a folder
./bin/upload.sh ./backup/backup2.zip backup2    # a file
```

The command does these steps:

1. It calculates the size of the content and the size of each part.
2. It gets the free space of each account. If one account does not have sufficient space for its part, the command stops before it uploads anything.
3. It makes the archive and divides it into parts.
4. It uploads each part to its account.
   - Box gets parts of 50 MB or more in smaller pieces.
5. If a backup with the same name exists, the new parts replace the old parts. If your Box plan has file versions, Box keeps the old parts as earlier versions.
6. It removes old parts of the same backup that the new upload does not use.

The command stops with exit code 0 if the upload is successful. Any other exit code means an error.

### Download and restore a backup

```bash
./bin/download.sh <archive_name> <path_to_directory>
```

Examples:

```bash
./bin/download.sh backup1 ./restore/
./bin/download.sh backup2 ./restore
```

The command does these steps:

1. It finds the parts of the backup in all accounts.
2. It skips accounts that have no part of this backup.
3. It downloads the parts, joins them in the correct order, and extracts the archive.
4. It deletes the temporary parts.

The archive keeps the name of the original file or folder. In the examples, the result is the folder `./restore/backup1` and the file `./restore/backup2.zip`.

If the target directory does not exist, the command makes it. Files with the same name in the target directory are replaced.

If a part is missing, the command stops with the message `Archive '<name>' is incomplete`.

### Check if a backup exists

```bash
./bin/exists.sh <archive_name>
```

| Output | Exit code | Meaning |
|---|---|---|
| `true` | 0 | At least one part of the backup exists. |
| `false` | 1 | No part of the backup exists. |
| (no output) | 2 | An error occurred. Read `error.log`. |

You can use the command in a script:

```bash
if ./bin/exists.sh backup1 >/dev/null; then
    echo "The backup exists."
fi
```

### Delete a backup

```bash
./bin/remove.sh <archive_name>
```

The command deletes all parts of the backup from all accounts. It shows the number of deleted parts.

If a part does not exist in an account, the command does not show an error. If the backup does not exist, the output is `0` and the exit code is 0.

**Caution:** the command deletes the backup permanently from your accounts. Box can keep the deleted files in its trash for some time.

## Access tokens and refresh tokens

mp-archive uses OAuth 2.0 to get access to Box. OAuth 2.0 uses two tokens.

| Token | Purpose | Time that it is valid |
|---|---|---|
| Access token | Each request to Box uses this token. | 60 minutes |
| Refresh token | mp-archive uses this token to get a new access token. | 60 days |

When you add an account with `bin/add-account.sh`, Box gives mp-archive the first access token and the first refresh token. mp-archive keeps them in these files:

```
/var/lib/mp-archive/box/<name>.access_token
/var/lib/mp-archive/box/<name>.refresh_token
```

### When mp-archive gets a new token

1. Before each request, mp-archive reads the expiry time of the access token.
2. If the access token is valid for more than 5 more minutes, mp-archive uses it.
3. If the access token is valid for 5 minutes or less, mp-archive sends the refresh token to Box.
4. Box sends a new access token and a new refresh token.
5. mp-archive saves the two new tokens. The old refresh token does not work again.

The 5-minute margin prevents an access token from expiring during a long upload.

If Box rejects an access token, mp-archive gets a new token one time and sends the request again.

### What happens when a token expires

- **The access token expires.** mp-archive gets a new access token automatically. You do not do anything.
- **The refresh token expires.** This occurs if no command uses the account for 60 days. Then mp-archive cannot get a new access token. The command stops, and `error.log` tells you to log in again.
- **You remove the access of the app in Box.** The result is the same as an expired refresh token.

To log in again, run `bin/add-account.sh` and log in as the Box user of the account. Log out of Box first, or use a private window:

```bash
./bin/add-account.sh
```

The script finds the account by the Box user. It does not add a new account. It renews the login of the existing account.

Each successful command gets a new refresh token. Thus, if a command runs at least one time in 60 days, you do not need to log in again.

**Do not edit, copy or delete the token files.** A copied refresh token stops working after the next refresh. If you delete the files, you must renew the login of the account.

If you change the `name` of an account in `box.json`, mp-archive cannot find the tokens of the account. Then renew the login of the account.

## Run a backup each day

You can use `cron` to run a backup automatically.

1. Open the cron table of the user who runs mp-archive:
   ```bash
   sudo crontab -u mparchive -e
   ```
2. Add a line such as this one:
   ```
   0 2 * * * /opt/mp-archive/bin/upload.sh /path/to/backup1 backup1 >> /var/log/mp-archive/cron.log 2>&1
   ```

Use full paths in the cron table, because cron does not start in the project folder.

This example uploads the backup each day at 02:00. Each run replaces the previous backup with the same name.

A daily backup also keeps the refresh tokens valid.

## Update mp-archive

The settings, the tokens and the logs are not in the project folder. Thus, an update of the code does not change them.

**If you used git (method A):**

```bash
cd /opt/mp-archive
sudo git pull
```

**If you did not use git (method B):** download the code again into the same folder:

```bash
curl -fsSL https://github.com/nchankov/mp-archive/archive/refs/heads/main.tar.gz \
  | sudo tar -xz --strip-components=1 -C /opt/mp-archive
```

After an update, compare `/opt/mp-archive/.env.example` with your `/etc/mp-archive/.env`. Add the new settings, if there are some.

Do not update while a backup runs.

## Logs and errors

mp-archive writes two log files in the log folder. The default log folder is `/var/log/mp-archive`. The setting `MPARCHIVE_LOG_DIR` changes it.

- `activity.log` records all actions and errors.
- `error.log` records only errors.

Each line has the time, the type of the message, the name of the script and the message.

| Error message | Cause | What to do |
|---|---|---|
| `no token. Run ./bin/add-account.sh and log in as ...` | The account has no login. | Run `./bin/add-account.sh` and log in as the Box user in the message. |
| `the refresh token is expired or revoked. Run ./bin/add-account.sh and log in as ...` | The refresh token expired, or the access of the app was removed. | Run `./bin/add-account.sh` and log in as the Box user in the message. |
| `PROVIDER is not set. Settings file not found: ...` | The settings file is not in the config folder. | Copy `.env.example` to `/etc/mp-archive/.env`, or set `MPARCHIVE_CONFIG_DIR`. |
| `Cannot create log directory: ...` | The user has no write access to the log folder. | Do step 2 of the setup. Until then, the messages go only to the screen. |
| `... must be an absolute path` | A folder setting has a relative path. | Write the full path, for example `/var/log/mp-archive`. |
| `Box app credentials are missing` | `.env` has no `BOX_APP_CLIENT_ID` or no `BOX_APP_SECRET`. | Write the two keys in `.env`. |
| `WARNING: .env has mode ...` | Other users can read `.env` or `box.json`. | Run `chmod 600 /etc/mp-archive/.env /etc/mp-archive/box.json`. |
| `WARNING: Accounts #A and #B are the same Box user` | Two accounts use the same Box user. | Use a different Box user for one account. |
| `... bytes free; part size ... bytes is required` | An account does not have sufficient free space. | Free some space, or add an account. |
| `Archive '<name>' not found in any account` | No part of the backup exists. | Check the archive name with `./bin/exists.sh`. |
| `Archive '<name>' is incomplete` | One or more parts are missing. | Make sure that all accounts that hold parts are in `box.json` and are active. |
| `Cannot list the files of account #N` | mp-archive cannot read the account. | Read the lines above this error in `error.log`. |
| `the same token key` | Two accounts have the same `name`, or have no `name` and use the same app. | Add a unique `name` to each account in `box.json`. |

mp-archive never writes a token or a secret to a log.

## Security

- `.env` contains the Client Secret of your Box app. Keep the mode of this file at `600`.
- `box.json` contains the names and the e-mail addresses of your accounts. Keep the mode of this file at `600`.
- `/var/lib/mp-archive/box/` contains your tokens. mp-archive makes this folder with mode `700` and the files with mode `600`.
- Do not put `box.json`, `.env` or the token files in git or in a public backup. These files are not in the project folder. The `.gitignore` file also keeps them out of git if you copy them there.
- If a secret or a token leaks, do these steps:
  1. Make a new Client Secret in the Developer Console.
  2. Write the new secret in `.env`.
  3. Renew the login of each account with `bin/add-account.sh`.

## Tests

The automatic tests do not connect to Box. Run them from the project folder:

```bash
bash tests/run.sh
```

The tests use temporary folders. They do not change the files in `/etc/mp-archive`, `/var/lib/mp-archive` or `/var/log/mp-archive`.

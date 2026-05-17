# vendor/ — Oracle Instant Client ZIPs

Place the Oracle Instant Client ZIP files for **Linux x86_64** here before
running `docker build` / `make build`. The Dockerfile copies them in at
build time and installs them inside the container.

## Required files

| File pattern | Required? |
|---|---|
| `instantclient-basic-linux.x64-*.zip` | YES |
| `instantclient-sdk-linux.x64-*.zip` | YES |
| `instantclient-sqlplus-linux.x64-*.zip` | optional, but recommended |

## Download

1. Go to: https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
2. Choose the version that matches or **exceeds** your Oracle source DB version.
3. Download the three ZIPs above (a free Oracle account is required).
4. Drop them in this directory — no need to unzip.

## Example (version 21.x)

```
vendor/
├── instantclient-basic-linux.x64-21.13.0.0.0dbru.zip
├── instantclient-sdk-linux.x64-21.13.0.0.0dbru.zip
└── instantclient-sqlplus-linux.x64-21.13.0.0.0dbru.zip
```

## Notes

- These ZIPs are **not** committed to source control (see `.dockerignore`).
- They are only needed at **build time**; the image bundles them after that.
- The `.dockerignore` is already configured to include `vendor/*.zip`.

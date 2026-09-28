# Readcast audio Worker

Deploy this Worker once and keep its `workers.dev` name and account subdomain
unchanged after publishing an episode. Create a private R2 bucket named
`readcast-audio` in Standard storage, then deploy with `npx wrangler deploy`.
The Worker binding keeps the bucket private; it never enables `r2.dev` access.

The Worker streams R2's `ReadableStream` response directly. It supports `GET`,
`HEAD`, single byte ranges (including suffix ranges), `206`, and `416` with
`Content-Range: bytes */<length>`. Malformed or multi-range headers are ignored
and served as a full `200`, as permitted for range requests.

For Readcast, set `READCAST_WORKER_URL` to the deployed origin and configure
`R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY`.
Create an R2 API token with object read and write permissions. Readcast's setup
check lists a bucket page and probes the Worker with a deliberately missing
object; it does not upload anything. Keep the credentials in environment
variables or a local secret manager. The upload helper records the Worker origin on its first
successful upload and rejects a later address change.

Run the contract suite with `node --test tests/worker/audio.test.js`.

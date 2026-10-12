Each folder here is one self-contained static site: an index.html with inline CSS.
Each folder is mounted read-only into its own nginx:alpine container (to /usr/share/nginx/html), so sites can't share files.

To add a site: make a new folder, copy the `hub` block in `docker/docker-compose.yml` with a new name, folder and `127.0.0.1` port, add a hostname for it in the tunnel config, and run `docker compose up -d`.

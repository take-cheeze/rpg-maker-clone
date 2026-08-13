- **CORS proxy**: the Worker's upstream fetch now sends a browser-like
  `User-Agent` header. Workers' `fetch()` sends none by default, and some
  CDNs/WAFs (the CloudFront distribution behind `cdn.tkool.jp`, notably) treat
  that as bot traffic and serve an anti-hotlink error page instead of the
  requested file — RTP downloads through the proxy were hitting exactly this.

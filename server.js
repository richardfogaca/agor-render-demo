// Minimal zero-dependency demo service. Markers come from env so each Agor
// branch environment can be told apart by URL.
const http = require('http');

const branch = process.env.AGOR_BRANCH || 'unknown';
const pageMarker = process.env.PAGE_MARKER || `page-${branch}`;
const healthMarker = process.env.HEALTH_MARKER || `health-${branch}`;

http
  .createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', branch, marker: healthMarker }));
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(`<!doctype html><title>${pageMarker}</title><h1>${pageMarker}</h1><p>branch: ${branch}</p>`);
  })
  .listen(process.env.PORT || 3000, () => console.log(`listening: ${pageMarker}`));

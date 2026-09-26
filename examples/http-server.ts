import http from 'std:http'

const server = http.serve({
  port: 8000,
  handler(request) {
    if (request.method === 'POST' && request.url === '/echo') {
      return { json: request.json() }
    }
    if (request.url === '/') return { body: 'Hello from Hao!\n' }
    return { status: 404, json: { error: 'Not found' } }
  },
})
console.log(`Listening on http://${server.hostname}:${server.port}`)
// Ctrl-C to exit, or call server.close() from your application.

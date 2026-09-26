import { serve } from 'std:http'
const server = serve({ port: 0, requestTimeoutMs: 150, async handler(req) {
  if (req.url === '/slow') await new Promise(resolve => setTimeout(resolve, 250))
  return { body: req.bytes() }
} })
console.log(server.port)

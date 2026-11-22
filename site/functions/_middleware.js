// Before every request: lm.frogwizard.net, the site's address before Loremaster became Lorebound, sends visitors
// on to the same page at lb.frogwizard.net, so old progress links and QR codes keep working.

const OLD_HOST = 'lm.frogwizard.net'
const NEW_HOST = 'lb.frogwizard.net'

export async function onRequest({ request, next }) {
  const url = new URL(request.url)
  if (url.hostname !== OLD_HOST) return next()
  url.hostname = NEW_HOST
  return Response.redirect(url.toString(), 301)
}

// Pages advanced-mode worker: initial HTML metadata from public content only.
const api = 'https://api.asodya.com/apps/annotations/v1';
const escape = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const webUrl = value => { try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) ? url.href : ''; } catch { return ''; } };
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/v1\/menu\/([^/]+)\/([^/]+)\/?$/);
    if (!match || !['GET','HEAD'].includes(request.method)) return env.ASSETS.fetch(request);
    let article;
    try {
      const content = new URL(`${api}/posts/${encodeURIComponent(decodeURIComponent(match[2]))}`);
      content.searchParams.set('channel', decodeURIComponent(match[1]));
      if (url.searchParams.has('lang')) content.searchParams.set('lang',url.searchParams.get('lang'));
      const response = await fetch(content, {headers:{accept:'application/json'},signal:AbortSignal.timeout(5000), redirect:'error'});
      if (response.ok) article = await response.json();
      else if (response.status >= 500) return env.ASSETS.fetch(request);
    } catch { return env.ASSETS.fetch(request); }
    const shell = await env.ASSETS.fetch(new Request(new URL('/index.html',url), {method:'GET'}));
    let html = await shell.text();
    const title = article ? `${article.title} · Annotations` : 'Annotations · Asodya';
    const description = article?.summary ?? 'Study notes, sources and interactive reports.';
    const canonical = new URL(url.pathname,url.origin);
    if (article?.language) canonical.searchParams.set('lang',article.language);
    const image = webUrl(article?.cover_url) || `${url.origin}/icons/Icon-512.png`;
    html = html.replace(/<title>[\s\S]*?<\/title>/i,`<title>${escape(title)}</title>`)
      .replace(/<meta\s+(?:name|property)=["'](?:description|og:[^"']+|twitter:[^"']+)["'][^>]*>/gi,'');
    const meta = `<meta name="description" content="${escape(description)}"><meta property="og:type" content="article"><meta property="og:title" content="${escape(title)}"><meta property="og:description" content="${escape(description)}"><meta property="og:url" content="${escape(canonical.href)}"><meta property="og:image" content="${escape(image)}"><meta name="twitter:card" content="summary_large_image"><link rel="canonical" href="${escape(canonical.href)}">`;
    html = html.replace('</head>',`${meta}</head>`);
    return new Response(request.method === 'HEAD' ? null : html,{status:article?200:404,headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}});
  }
};

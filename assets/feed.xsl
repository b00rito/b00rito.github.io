<?xml version="1.0" encoding="utf-8"?>
<!--
  Browser stylesheet for /feed.xml. Referenced by an <?xml-stylesheet?>
  processing instruction in assets/feed.xml. Turns the raw Atom feed into a
  readable page when a human opens the feed URL in a browser. Feed readers
  ignore this file entirely.
-->
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:atom="http://www.w3.org/2005/Atom">

  <xsl:output method="html" encoding="utf-8" indent="yes"
    doctype-system="about:legacy-compat"/>

  <xsl:template match="/atom:feed">
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title><xsl:value-of select="atom:title"/> - web feed</title>
        <style>
          :root { color-scheme: light dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
              Helvetica, Arial, sans-serif;
            background: #fdfdfd;
            color: #1f2328;
          }
          main { max-width: 44rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
          h1 { font-size: 1.7rem; margin: 0 0 .25rem; }
          .sub { margin: 0 0 1.75rem; color: #59636e; }
          .note {
            border: 1px solid #d0d7de;
            border-left: 4px solid #0969da;
            border-radius: 6px;
            padding: 1rem 1.15rem;
            background: #f6f8fa;
            margin-bottom: 2.5rem;
          }
          .note p { margin: .5rem 0 0; }
          .url {
            margin-top: .6rem;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: .9rem;
            word-break: break-all;
            background: rgba(0, 0, 0, .05);
            padding: .35rem .5rem;
            border-radius: 4px;
          }
          .muted { color: #59636e; font-size: .9rem; }
          h2 {
            font-size: 1rem;
            text-transform: uppercase;
            letter-spacing: .04em;
            color: #59636e;
            border-bottom: 1px solid #d0d7de;
            padding-bottom: .4rem;
          }
          article { padding: 1rem 0; border-bottom: 1px solid #eaeef2; }
          article h3 { margin: 0 0 .3rem; font-size: 1.15rem; }
          .date {
            margin: 0 0 .4rem;
            font-size: .85rem;
            color: #59636e;
            font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
          }
          article p:last-child { margin: 0; color: #1f2328; }
          a { color: #0969da; text-decoration: none; }
          a:hover { text-decoration: underline; }
          @media (prefers-color-scheme: dark) {
            body { background: #0d1117; color: #e6edf3; }
            .sub, .muted, .date, h2 { color: #9198a1; }
            .note {
              background: #161b22;
              border-color: #30363d;
              border-left-color: #1f6feb;
            }
            .url { background: rgba(255, 255, 255, .06); }
            h2 { border-bottom-color: #30363d; }
            article { border-bottom-color: #21262d; }
            article p:last-child { color: #e6edf3; }
            a { color: #4493f8; }
          }
        </style>
      </head>
      <body>
        <main>
          <h1><xsl:value-of select="atom:title"/></h1>
          <p class="sub"><xsl:value-of select="atom:subtitle"/></p>

          <div class="note">
            <strong>This is a web feed</strong> (RSS / Atom). It is meant to be
            read in a feed reader, not a browser. To subscribe, copy this URL
            into your reader:
            <div class="url">
              <xsl:value-of select="atom:link[@rel='self']/@href"/>
            </div>
            <p class="muted">
              Just browsing?
              <a>
                <xsl:attribute name="href">
                  <xsl:value-of select="atom:link[@rel='alternate']/@href"/>
                </xsl:attribute>
                Go to the site
              </a>.
            </p>
          </div>

          <h2>Latest posts</h2>
          <xsl:for-each select="atom:entry">
            <article>
              <h3>
                <a>
                  <xsl:attribute name="href">
                    <xsl:value-of select="atom:link/@href"/>
                  </xsl:attribute>
                  <xsl:value-of select="atom:title"/>
                </a>
              </h3>
              <p class="date">
                <xsl:value-of select="substring(atom:published, 1, 10)"/>
              </p>
              <p><xsl:value-of select="atom:summary"/></p>
            </article>
          </xsl:for-each>
        </main>
      </body>
    </html>
  </xsl:template>

</xsl:stylesheet>

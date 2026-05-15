import React, { useState } from 'react'

const CHANNELS = [
  { key: 'blog_post', label: 'Blog Post', icon: 'pencil', filename: 'blog_post.md' },
  { key: 'social_media', label: 'Social Media', icon: 'share', filename: 'social_media.md' },
  { key: 'email_newsletter', label: 'Email Newsletter', icon: 'mail', filename: 'email_newsletter.md' },
  { key: 'seo_metadata', label: 'SEO Metadata', icon: 'search', filename: 'seo_metadata.md' },
]

function ContentDisplay({ contentPieces, isGenerating }) {
  const [copiedChannel, setCopiedChannel] = useState(null)

  const copyToClipboard = (channel, text) => {
    navigator.clipboard.writeText(text)
    setCopiedChannel(channel)
    setTimeout(() => setCopiedChannel(null), 2000)
  }

  const downloadContent = (filename, text) => {
    const blob = new Blob([text], { type: 'text/markdown' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <div className="content-display">
      <h2 className="content-display-title">Generated Content</h2>
      <div className="channel-grid">
        {CHANNELS.map(({ key, label, icon, filename }) => {
          const content = contentPieces[key]
          const isReady = !!content
          const isWaiting = !isReady && isGenerating

          return (
            <div key={key} className={`channel-card ${isReady ? 'ready' : ''} ${isWaiting ? 'waiting' : ''}`}>
              <div className="channel-header">
                <span className="channel-label">{label}</span>
                {isReady && (
                  <div className="channel-actions">
                    <button
                      className="channel-btn"
                      onClick={() => copyToClipboard(key, content)}
                      title="Copy to clipboard"
                    >
                      {copiedChannel === key ? 'Copied!' : 'Copy'}
                    </button>
                    <button
                      className="channel-btn"
                      onClick={() => downloadContent(filename, content)}
                      title={`Download as ${filename}`}
                    >
                      Download
                    </button>
                  </div>
                )}
              </div>

              <div className="channel-body">
                {isWaiting && (
                  <div className="channel-loading">
                    <div className="spinner-small"></div>
                    <span>Generating...</span>
                  </div>
                )}
                {!isReady && !isWaiting && (
                  <div className="channel-empty">Waiting to start</div>
                )}
                {isReady && (
                  <div className="channel-content">
                    <MarkdownRenderer content={content} />
                  </div>
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function MarkdownRenderer({ content }) {
  const renderMarkdown = (text) => {
    if (!text) return ''
    text = text.replace(/^### (.*$)/gim, '<h3>$1</h3>')
    text = text.replace(/^## (.*$)/gim, '<h2>$1</h2>')
    text = text.replace(/^# (.*$)/gim, '<h1>$1</h1>')
    text = text.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
    text = text.replace(/\*(.*?)\*/g, '<em>$1</em>')
    text = text.replace(/\n/g, '<br />')
    text = text.replace(/^\* (.*$)/gim, '<li>$1</li>')
    text = text.replace(/(<li>.*<\/li>)/s, '<ul>$1</ul>')
    return text
  }

  return (
    <div
      className="markdown-content"
      dangerouslySetInnerHTML={{ __html: renderMarkdown(content) }}
    />
  )
}

export default ContentDisplay

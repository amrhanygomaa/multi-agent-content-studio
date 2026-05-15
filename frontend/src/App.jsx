import React, { useState } from 'react'
import ContentForm from './components/ContentForm'
import ContentDisplay from './components/ContentDisplay'
import ProgressIndicator from './components/ProgressIndicator'
import TextAnalyzer from './components/TextAnalyzer'
import './styles/App.css'

function App() {
  const [activeTab, setActiveTab] = useState('create')
  const [isGenerating, setIsGenerating] = useState(false)
  const [progress, setProgress] = useState([])
  // Each channel arrives independently: { blog_post, social_media, email_newsletter, seo_metadata }
  const [contentPieces, setContentPieces] = useState({})
  const [error, setError] = useState(null)
  const [lastFormData, setLastFormData] = useState(null)

  const handleContentGeneration = (formData) => {
    setLastFormData(formData)
    setIsGenerating(true)
    setProgress([])
    setContentPieces({})
    setError(null)

    const apiUrl = '/api/create-content'

    fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        topic: formData.topic,
        target_audience: formData.targetAudience,
        tone: formData.tone,
        keywords: formData.keywords,
      }),
    })
      .then(response => {
        const reader = response.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''

        const readStream = () => {
          reader.read().then(({ done, value }) => {
            if (done) {
              setIsGenerating(false)
              return
            }

            // Buffer across chunks so large JSON payloads (e.g. blog post)
            // are not split mid-line and silently dropped by JSON.parse
            buffer += decoder.decode(value, { stream: true })
            const lines = buffer.split('\n')
            buffer = lines.pop() // keep any incomplete trailing line

            lines.forEach(line => {
              if (line.startsWith('data: ')) {
                try {
                  const data = JSON.parse(line.substring(6))

                  if (data.type === 'status') {
                    setProgress(prev => [...prev, { type: 'info', message: data.message }])
                  } else if (data.type === 'content_piece') {
                    // Accumulate chunks — agents stream output in multiple pieces
                    setContentPieces(prev => ({
                      ...prev,
                      [data.channel]: (prev[data.channel] || '') + data.content
                    }))
                  } else if (data.type === 'event') {
                    setProgress(prev => [...prev, {
                      type: 'event',
                      author: data.author,
                      preview: data.content_preview
                    }])
                  } else if (data.type === 'complete') {
                    setIsGenerating(false)
                  } else if (data.type === 'error') {
                    setError({ message: data.message, retryable: data.retryable })
                    setIsGenerating(false)
                  }
                } catch (e) {
                  console.error('Error parsing SSE data:', e)
                }
              }
            })

            readStream()
          })
        }

        readStream()
      })
      .catch(err => {
        setError({ message: 'Could not connect to the server. Please check if the backend is running.', retryable: true })
        setIsGenerating(false)
      })
  }

  const hasContent = Object.keys(contentPieces).length > 0

  return (
    <div className="app">
      <header className="app-header">
        <h1>Content Creation Studio</h1>
        <p>AI-Powered Multi-Agent Content Generation</p>
      </header>

      <main className="app-main">
        <div className="main-tabs">
          <button
            className={`main-tab ${activeTab === 'create' ? 'active' : ''}`}
            onClick={() => setActiveTab('create')}
          >
            Create Content
          </button>
          <button
            className={`main-tab ${activeTab === 'analyze' ? 'active' : ''}`}
            onClick={() => setActiveTab('analyze')}
          >
            Analyze Text
          </button>
        </div>

        <div className="content-container">
          {activeTab === 'create' && (
            <>
              <div className="form-section">
                <ContentForm
                  onSubmit={handleContentGeneration}
                  isGenerating={isGenerating}
                />
              </div>

              {(isGenerating || progress.length > 0) && (
                <div className="progress-section">
                  <ProgressIndicator
                    progress={progress}
                    isGenerating={isGenerating}
                  />
                </div>
              )}

              {error && (
                <div className="error-section">
                  <div className="error-banner">
                    <div className="error-icon">&#9888;</div>
                    <div className="error-body">
                      <p className="error-text">{error.message}</p>
                      {error.retryable && lastFormData && (
                        <button
                          className="retry-button"
                          onClick={() => handleContentGeneration(lastFormData)}
                        >
                          Try Again
                        </button>
                      )}
                    </div>
                  </div>
                </div>
              )}

              {hasContent && (
                <ContentDisplay
                  contentPieces={contentPieces}
                  isGenerating={isGenerating}
                />
              )}
            </>
          )}

          {activeTab === 'analyze' && (
            <div className="form-section">
              <TextAnalyzer />
            </div>
          )}
        </div>
      </main>

      <footer className="app-footer">
        <p>Powered by Google ADK & Gemini AI</p>
      </footer>
    </div>
  )
}

export default App

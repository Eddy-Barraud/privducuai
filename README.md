# Privducai

A fast, efficient, and privacy-focused web search assistant for macOS, powered by DuckDuckGo and Apple's on-device AI frameworks.

## Features

- 🔍 **DuckDuckGo Integration**: Privacy-respecting web search
- ⚡ **Optimized for M3 MacBook**: Efficient power management and fast performance
- 🧠 **On-Device AI**: Uses Apple's NaturalLanguage framework for summaries
- 📝 **Concise Summaries**: Get quick insights without reading through multiple pages
- 🔗 **Direct Links**: Easy access to sources for detailed information
- 🔒 **Privacy-First**: No tracking, no data collection

## Overview

Privducai (Privacy + Education + AI) is a native macOS application that provides a DuckDuckGo assistant experience similar to Perplexica, but optimized for Apple Silicon Macs. It combines efficient web search with on-device AI summarization to help you find and understand information quickly without draining your battery.

### How It Works

1. **Search**: Enter your query in the search bar
2. **Fetch**: The app queries DuckDuckGo and retrieves top results
3. **Summarize**: Apple's NaturalLanguage framework analyzes the results
4. **Present**: Get a concise summary with links to full sources

## Architecture

```
Privducai/
├── Models/
│   └── SearchResult.swift          # Data models for search results
├── Services/
│   ├── DuckDuckGoService.swift     # Web search integration
│   └── AIService.swift             # On-device AI summarization
├── Views/
│   └── SearchView.swift            # Main search interface
├── ContentView.swift               # Root view
└── PrivducaiApp.swift             # App entry point
```

## Technical Details

### Power Efficiency

- **URLSession Configuration**: Optimized for low power consumption
- **Request Caching**: Reduces redundant network requests
- **Limited Results**: Fetches only top 10 results per query
- **On-Device Processing**: No external API calls for AI processing

### AI Summarization

The app uses Apple's NaturalLanguage framework instead of cloud-based LLMs:
- **NLTokenizer**: Sentence segmentation
- **NLTagger**: Part-of-speech tagging and key term extraction
- **Relevance Scoring**: Custom algorithm to identify most relevant sentences
- **Extractive Summarization**: Selects key information from search results

### Privacy

- Uses DuckDuckGo's privacy-focused search
- All AI processing happens on-device
- No user data collection or tracking
- No external API calls for language processing

## Requirements

- macOS 13.0 or later
- Apple Silicon (M1, M2, M3) or Intel Mac
- Internet connection for web searches

## Building

1. Open `Privducai.xcodeproj` in Xcode
2. Select your target device
3. Build and run (⌘R)

## Usage Tips

- Use natural language queries for best results
- The AI summary appears automatically after search
- Click on result titles to open full articles in your browser
- Toggle the summary on/off to focus on results

## Future Enhancements

Potential improvements for future versions:
- Integration with Apple Intelligence (when available)
- Search history and favorites
- Custom search filters
- Keyboard shortcuts
- Dark mode optimization

## License

This project is open source and available for educational purposes.

## Credits

Created by Eddy Barraud


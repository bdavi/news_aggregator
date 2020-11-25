# frozen_string_literal: true

require 'rss'
require 'open-uri'
require 'action_view'

# Channel related code
module Channels
  class FeedSynchronizer
    include ActionView::Helpers::SanitizeHelper

    attr_reader :channel, :feed

    delegate :last_build_date, to: :channel

    def initialize(channel)
      @channel = channel
    end

    def call
      download_feed

      return unless requires_update?

      update_channel
      update_articles
    end

    def download_feed
      @feed = RSS::Parser.parse(
        URI.parse(channel.url).read
      )
    end

    def requires_update?
      return true unless last_build_date

      last_build_date < feed.channel.lastBuildDate
    end

    def update_channel
      channel.update(last_build_date: feed.channel.lastBuildDate)
    end

    # rubocop:disable Metrics/MethodLength
    def update_articles
      feed.items.each do |item|
        article = Article.find_or_initialize_by(guid: item.guid.content)

        article.update(
          channel: channel,
          title: item.title,
          description: item.description,
          published_at: item.pubDate,
          content: item.content_encoded,
          url: item.link
        )
      end
    end
    # rubocop:enable Metrics/MethodLength
  end
end

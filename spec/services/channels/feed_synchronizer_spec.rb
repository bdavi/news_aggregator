# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channels::FeedSynchronizer, type: :service do
  context 'when the feed is invalid' do
    describe '#download_feed' do
      it 'raises an error' do
        channel = build_stubbed(:channel, url: 'https://www.google.com')
        synchronizer = described_class.new(channel)

        VCR.use_cassette('download_invalid_feed', re_record_interval: 7.days) do
          expect {
            synchronizer.download_feed
          }.to raise_error(RSS::NotWellFormedError)
        end
      end
    end
  end

  describe '#requires_update?' do
    it 'returns true when channel has no last_build_date' do
      channel = Channel.new(last_build_date: nil)
      synchronizer = described_class.new(channel)

      expect(synchronizer.requires_update?).to be true
    end
  end

  context 'with a valid feed' do
    # NOTE: DO NOT UPDATE THE 'download_valid_feed' VCR CASSETTE WITHOUT
    # ALSO UPDATING THE FOLLOWING LET BLOCKS.
    #
    # The 'valid feed' specs depend rigidly on the current values in
    # that cassette (which does not expire). Coupling the specs to the fixture
    # in this way isn't ordinarily ideal, but because the RSS standard is
    # unlikey to change we are reasonably safe.

    around { |example| VCR.use_cassette('download_valid_feed', &example) }

    let(:cassette_data) do
      {
        last_build: DateTime.new(2020, 11, 20, 16, 55, 56),
        channel_title: 'Reuters News Agency',
        item_count: 10,
        first_item: {
          title: 'Reuters ahead with Turkey interest rate hike; market reacts',
          guid: 'https://www.reutersagency.com/en/?post_type=best&p=223646',
          published_at: DateTime.new(2020, 11, 19, 19, 1, 59),
          description: 'Reuters was ahead in reporting Turkey’s central bank aggressively ' \
            "raising its policy rate by 475 basis points to 15% on […]\nThe post Reuters " \
            'ahead with Turkey interest rate hike; market reacts appeared first on Reuters ' \
            "News Agency.\n",
          content: "\nReuters was ahead in reporting Turkey’s central bank aggressively raising " \
            'its policy rate by 475 basis points to 15% on Nov. 19, at the closely-watched first ' \
            "meeting on rates since the appointment of a new governor, Naci Agbal.\n\n\n\n\nThe " \
            'post Reuters ahead with Turkey interest rate hike; market reacts appeared first on ' \
            "Reuters News Agency.\n"
        }
      }
    end
    let(:url) { 'https://www.reutersagency.com/feed/?taxonomy=best-topics&post_type=best' }
    let(:synced_day_before_last_build) { cassette_data[:last_build] - 1.day }
    let(:synced_on_last_build) { cassette_data[:last_build] }

    def new_channel(last_build_date = DateTime.now)
      Channel.new(url: url, last_build_date: last_build_date)
    end

    def create_channel(last_build_date = DateTime.now)
      create(:channel, url: url, last_build_date: last_build_date)
    end

    describe '#download_feed' do
      it 'downloads and parses the feed' do
        synchronizer = described_class.new(new_channel)

        synchronizer.download_feed
        parsed_download = synchronizer.feed

        expect(parsed_download.channel.title).to eq cassette_data[:channel_title]
        expect(parsed_download.channel.lastBuildDate).to eq cassette_data[:last_build]
        expect(parsed_download.items.first.title).to eq cassette_data[:first_item][:title]
      end
    end

    describe '#requires_update?' do
      it 'returns true when the sync is stale' do
        channel = new_channel(synced_day_before_last_build)
        synchronizer = described_class.new(channel).tap(&:download_feed)

        expect(synchronizer.requires_update?).to be true
      end

      it 'returns false when sync is current' do
        channel = new_channel(synced_on_last_build)
        synchronizer = described_class.new(channel).tap(&:download_feed)

        expect(synchronizer.requires_update?).to be false
      end
    end

    describe '#update_channel' do
      it 'updates the last_build_date from the feed' do
        channel = create_channel(synced_day_before_last_build)
        synchronizer = described_class.new(channel).tap(&:download_feed)

        synchronizer.update_channel

        channel.reload
        expect(channel.last_build_date).to eq cassette_data[:last_build]
      end
    end

    describe '#update_articles' do
      it 'creates articles from the feed' do
        channel = create_channel(synced_day_before_last_build)
        synchronizer = described_class.new(channel).tap(&:download_feed)

        expect {
          synchronizer.update_articles
        }.to change(Article, :count).by(cassette_data[:item_count])

        article = Article.find_by(guid: cassette_data[:first_item][:guid])
        expect(article).to have_attributes(cassette_data[:first_item])
        expect(article.channel).to eq channel
      end

      it 'updates existing articles matching guid' do
        channel = create_channel
        synchronizer = described_class.new(channel).tap(&:download_feed)
        article = create(
          :article,
          channel: channel,
          guid: cassette_data[:first_item][:guid],
          title: 'abc123'
        )

        synchronizer.update_articles

        article.reload
        expect(article.title).to eq cassette_data[:first_item][:title]
      end
    end

    describe '#call' do
      it 'downloads the feed and updates' do
        channel = create_channel(synced_day_before_last_build)
        synchronizer = described_class.new(channel)

        expect {
          synchronizer.call
        }.to change(Article, :count).by(cassette_data[:item_count])

        expect(synchronizer.feed).not_to be_nil
        expect(channel.reload.last_build_date).to eq cassette_data[:last_build]
      end

      it 'downloads the feed but does not update when already current' do
        channel = create_channel(synced_on_last_build)
        synchronizer = described_class.new(channel)

        expect {
          synchronizer.call
        }.not_to change(Article, :count)

        expect(synchronizer.feed).not_to be_nil
        expect(channel.reload.last_build_date).to eq cassette_data[:last_build]
      end
    end
  end
end
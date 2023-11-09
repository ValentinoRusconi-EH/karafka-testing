# frozen_string_literal: true

require 'waterdrop'
require 'karafka/testing/errors'
require 'karafka/testing/spec_consumer_client'
require 'karafka/testing/spec_producer_client'
require 'karafka/testing/minitest/proxy'

module Karafka
  module Testing
    # All the things related to extra functionalities needed to easier spec out
    # Karafka things using Minitest
    module Minitest
      # Minitest helpers module that needs to be included
      module Helpers
        class << self
          def included(base)
            base.class_eval do
              setup do
                @karafka = Karafka::Testing::Minitest::Proxy.new(self)
                @_karafka_consumer_messages = []
                @_karafka_consumer_client = Karafka::Testing::SpecConsumerClient.new
                @_karafka_producer_client = Karafka::Testing::SpecProducerClient.new(self)

                @_karafka_consumer_messages.clear
                @_karafka_producer_client.reset

                Karafka.producer.stubs(:client).returns(@_karafka_producer_client)
              end
            end
          end
        end

        # Creates a consumer instance for a given topic
        #
        # @param requested_topic [String, Symbol] name of the topic for which we want to
        #   create a consumer instance
        # @param requested_consumer_group [String, Symbol, nil] optional name of the consumer group
        #   if we have multiple consumer groups listening on the same topic
        # @return [Object] Karafka consumer instance
        # @raise [Karafka::Testing::Errors::TopicNotFoundError] raised when we're unable to find
        #   topic that was requested
        #
        # @example Creates a consumer instance with settings for `my_requested_topic`
        # consumer = @karafka.consumer_for(:my_requested_topic)
        def _karafka_consumer_for(requested_topic, requested_consumer_group = nil)
          selected_topics = _karafka_consumer_find_candidate_topics(
            requested_topic.to_s,
            requested_consumer_group.to_s
          )

          raise Errors::TopicInManyConsumerGroupsError, requested_topic if selected_topics.size > 1
          raise Errors::TopicNotFoundError, requested_topic if selected_topics.empty?

          _karafka_build_consumer_for(selected_topics.first)
        end

        # Adds a new Karafka message instance if needed with given payload and options into an
        # internal consumer buffer that will be used to simulate messages delivery to the consumer
        #
        # @param message [Hash] message that was sent to Kafka
        # @example Send a json message to consumer
        #
        # @karafka.produce({ 'hello' => 'world' }.to_json)
        #
        # @example Send a json message to consumer and simulate, that it is partition 6
        # @karafka.produce({ 'hello' => 'world' }.to_json, 'partition' => 6)
        def _karafka_add_message_to_consumer_if_needed(message)
          # Consumer needs to be defined in order to pass messages to it
          return unless defined?(consumer)
          # We're interested in adding message to consumer only when it is a Karafka consumer
          # Users may want to test other things (models producing messages for example) and in
          # their case consumer will not be a consumer
          return unless consumer.is_a?(Karafka::BaseConsumer)
          # We target to the consumer only messages that were produced to it, since specs may also
          # produce other messages targeting other topics
          return unless message[:topic] == consumer.topic.name

          # Build message metadata and copy any metadata that would come from the message
          metadata = _karafka_message_metadata_defaults

          metadata.keys.each do |key|
            next unless message.key?(key)

            metadata[key] = message.fetch(key)
          end

          # Add this message to previously produced messages
          _karafka_consumer_messages << Karafka::Messages::Message.new(
            message[:payload],
            Karafka::Messages::Metadata.new(metadata).freeze
          )

          # Update batch metadata
          batch_metadata = Karafka::Messages::Builders::BatchMetadata.call(
            _karafka_consumer_messages,
            consumer.topic,
            0,
            Time.now
          )

          # Update consumer messages batch
          consumer.messages = Karafka::Messages::Messages.new(
            _karafka_consumer_messages,
            batch_metadata
          )
        end

        # Produces message with a given payload to the consumer matching topic
        # @param payload [String] payload we want to dispatch
        # @param metadata [Hash] any metadata we want to dispatch alongside the payload
        def _karafka_produce(payload, metadata = {})
          Karafka.producer.produce_sync(
            {
              topic: consumer.topic.name,
              payload:
            }.merge(metadata)
          )
        end

        # @return [Array<Hash>] messages that were produced
        def _karafka_produced_messages
          _karafka_producer_client.messages
        end

        private

        # @return [Hash] message default options
        def _karafka_message_metadata_defaults
          {
            deserializer: consumer.topic.deserializer,
            timestamp: Time.now,
            headers: {},
            key: nil,
            offset: _karafka_consumer_messages.size,
            partition: 0,
            received_at: Time.now,
            topic: consumer.topic.name
          }
        end

        # Builds the consumer instance based on the provided topic
        #
        # @param topic [Karafka::Routing::Topic] topic for which we want to build the consumer
        # @return [Object] karafka consumer
        def _karafka_build_consumer_for(topic)
          coordinators = Karafka::Processing::CoordinatorsBuffer.new(
            Karafka::Routing::Topics.new([topic])
          )

          consumer = topic.consumer.new
          consumer.producer = Karafka::App.producer
          # Inject appropriate strategy so needed options and components are available
          strategy = Karafka::App.config.internal.processing.strategy_selector.find(topic)
          consumer.singleton_class.include(strategy)
          consumer.client = _karafka_consumer_client
          consumer.coordinator = coordinators.find_or_create(topic.name, 0)
          consumer.coordinator.seek_offset = 0
          # Indicate usage as for tests no direct enqueuing happens
          consumer.instance_variable_set('@used', true)
          consumer
        end

        # Finds all the routing topics matching requested topic within all topics or within
        # provided consumer group based on name
        #
        # @param requested_topic [String] requested topic name
        # @param requested_consumer_group [String] requested consumer group or nil to look in all
        # @return [Array<Karafka::Routing::Topic>] all matching topics
        #
        # @note Since we run the lookup on subscription groups, the search will automatically
        #   expand with matching patterns
        def _karafka_consumer_find_candidate_topics(requested_topic, requested_consumer_group)
          _karafka_consumer_find_subscription_groups(requested_consumer_group)
            .map(&:topics)
            .filter_map do |topics|
              topics.find(requested_topic.to_s)
            rescue Karafka::Errors::TopicNotFoundError
              nil
            end
        end

        # Finds subscription groups from the requested consumer group or selects all if no
        # consumer group specified
        # @param requested_consumer_group [String] requested consumer group or nil to look in all
        # @return [Array<Karafka::Routing::SubscriptionGroup>] requested subscription groups
        def _karafka_consumer_find_subscription_groups(requested_consumer_group)
          if requested_consumer_group && !requested_consumer_group.empty?
            ::Karafka::App
              .subscription_groups
              # Find matching consumer group
              .find { |cg, _sgs| cg.name == requested_consumer_group.to_s }
              # Raise error if not found
              .tap { |cg| cg || raise(Errors::ConsumerGroupNotFound, requested_consumer_group) }
              # Since lookup was on a hash, get the value, that is subscription groups
              .last
          else
            ::Karafka::App
              .subscription_groups
              .values
              .flatten
          end
        end
      end
    end
  end
end

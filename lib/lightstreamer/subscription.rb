module Lightstreamer
  # This class manages a subscription that can be used to stream data from a {Session}. Subscriptions should always be
  # created using {Session#build_subscription}. Subscriptions start receiving data after {#start} is called, and
  # streaming subscription data can be consumed by registering an asynchronous data callback using {#on_data}, or by
  # polling using {#item_data}.
  class Subscription
    # The session that this subscription is associated with.
    #
    # @return [Session]
    attr_reader :session

    # The names of the items to subscribe to.
    #
    # @return [Array]
    attr_reader :items

    # The names of the fields to subscribe to on the items.
    #
    # @return [Array]
    attr_reader :fields

    # The operation mode of this subscription.
    #
    # @return [:distinct, :merge]
    attr_reader :mode

    # The name of the data adapter from the Lightstreamer session's adapter set that should be used, or `nil` to use the
    # default data adapter.
    #
    # @return [String, nil]
    attr_reader :adapter

    # The selector for table items.
    #
    # @return [String, nil]
    attr_reader :selector

    # The maximum number of updates this subscription should receive per second. If this is set to zero, which is the
    # default, then there is no limit on the update frequency. If set to `:unfiltered` then unfiltered streaming will be
    # used for this subscription and it is possible for overflows to occur (see {#on_overflow}).
    #
    # @return [Float, :unfiltered]
    attr_reader :maximum_update_frequency

    # Initializes a new Lightstreamer subscription with the specified options.
    #
    # @param [Session] session The session this subscription is associated with.
    # @param [Hash] options The options to create the subscription with.
    #
    # @private
    def initialize(session, options)
      @session = session

      @items = options.fetch(:items)
      @fields = options.fetch(:fields)
      @mode = options.fetch(:mode).to_sym
      @adapter = options[:adapter]
      @selector = options[:selector]
      @maximum_update_frequency = options[:maximum_update_frequency] || 0.0

      @data_mutex = Mutex.new

      clear_data
      clear_callbacks
    end

    # Returns this subscription's unique identification number.
    #
    # @return [Fixnum]
    #
    # @private
    def id
      @id ||= self.class.next_id
    end

    # Starts streaming data for this Lightstreamer subscription. If an error occurs then a {LightstreamerError} subclass
    # will be raised.
    #
    # @param [Hash] options The options to start the subscription with.
    # @option options [Boolean] :silent Whether the subscription should be started in silent mode. In silent mode the
    #                 subscription is initiated on the server and begins buffering incoming data, however this data will
    #                 not be sent to the client for processing until {#unsilence} is called.
    def start(options = {})
      return if @active

      operation = options[:silent] ? :add_silent : :add
      options = { LS_table: id, LS_mode: mode.to_s.upcase, LS_id: items, LS_schema: fields, LS_data_adapter: adapter,
                  LS_requested_max_frequency: maximum_update_frequency, LS_selector: selector }

      session.control_request operation, options
      @active = true
    end

    # Unsilences this subscription if it was initially started in silent mode (by passing `silent: true` to {#start}).
    # If this subscription was not started in silent mode then this method has no effect. If an error occurs then a
    # {LightstreamerError} subclass will be raised.
    def unsilence
      session.control_request :start, LS_table: id if @active
    end

    # Stops streaming data for this Lightstreamer subscription. If an error occurs then a {LightstreamerError} subclass
    # will be raised.
    def stop
      session.control_request :delete, LS_table: id if @active
      @active = false
    end

    # Clears all current data stored for this subscription. New data will continue to be processed as it becomes
    # available.
    def clear_data
      @data = (0...items.size).map { {} }
    end

    # Adds the passed block to the list of callbacks that will be run when new data for this subscription arrives. The
    # block will be called on a worker thread and so the code that is run by the block must be thread-safe. The
    # arguments passed to the block are `|subscription, item_name, item_data, new_values|`. If {#mode} is `:distinct`
    # then the values of `item_data` and `new_values` will be the same.
    #
    # @param [Proc] callback The callback that is to be run when new data arrives.
    def on_data(&callback)
      @data_mutex.synchronize { @callbacks[:on_data] << callback }
    end

    # Adds the passed block to the list of callbacks that will be run when the server reports an overflow for this
    # subscription. The block will be called on a worker thread and so the code that is run by the block must be
    # thread-safe. The arguments passed to the block are `|subscription, item_name, overflow_size|`.
    #
    # @param [Proc] callback The callback that is to be run when an overflow is reported for this subscription.
    def on_overflow(&callback)
      @data_mutex.synchronize { @callbacks[:on_overflow] << callback }
    end

    # Removes all {#on_data} and {#on_overflow} callbacks present on this subscription.
    def clear_callbacks
      @data_mutex.synchronize { @callbacks = { on_data: [], on_overflow: [] } }
    end

    # Returns a copy of the current data of one of this subscription's items.
    #
    # @param [String] item_name The name of the item to return the current data for.
    #
    # @return [Hash] A copy of the item data.
    def item_data(item_name)
      index = @items.index item_name
      raise ArgumentError, 'Unknown item' unless index

      @data_mutex.synchronize { @data[index].dup }
    end

    # Sets the current data for the item with the specified name.
    #
    # @param [String] item_name The name of the item to set the data for.
    # @param [Hash] item_data The new data for the item.
    def set_item_data(item_name, item_data)
      index = @items.index item_name
      raise ArgumentError, 'Unknown item' unless index

      raise ArgumentError, 'Item data must be a hash' unless item_data.is_a? Hash

      @data_mutex.synchronize { @data[index] = item_data.dup }
    end

    # Processes a line of stream data if it is relevant to this subscription. This method is thread-safe and is intended
    # to be called by the session's processing thread.
    #
    # @param [String] line The line of stream data to process.
    #
    # @return [Boolean] Whether the passed line of stream data was relevant to this subscription and was successfully
    #         processed by it.
    #
    # @private
    def process_stream_data(line)
      process_update_message(line) || process_overflow_message(line)
    end

    # Returns the next unique subscription ID.
    #
    # @return [Fixnum]
    #
    # @private
    def self.next_id
      @next_id ||= 0
      @next_id += 1
    end

    private

    def process_update_message(line)
      update_message = UpdateMessage.parse line, id, items, fields
      return unless update_message

      @data_mutex.synchronize do
        process_new_values update_message.item_index, update_message.values
      end

      true
    end

    def process_new_values(item_index, new_values)
      data = @data[item_index]

      data.replace(new_values) if mode == :distinct
      data.merge!(new_values) if mode == :merge

      run_callbacks :on_data, @items[item_index], data, new_values
    end

    def process_overflow_message(line)
      overflow_message = OverflowMessage.parse line, id, items
      return unless overflow_message

      @data_mutex.synchronize do
        run_callbacks :on_overflow, @items[overflow_message.item_index], overflow_message.overflow_size
      end

      true
    end

    def run_callbacks(callback_type, *arguments)
      @callbacks.fetch(callback_type).each do |callback|
        callback.call self, *arguments
      end
    end
  end
end

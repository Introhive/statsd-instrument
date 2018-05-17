require 'monitor'

module StatsD::Instrument::Backends
  class UDPBackend < StatsD::Instrument::Backend

    DEFAULT_IMPLEMENTATION = :statsd

    EVENT_OPTIONS = {
      date_happened: 'd',
      hostname: 'h',
      aggregation_key: 'k',
      priority: 'p',
      source_type_name: 's',
      alert_type: 't',
    }

    SERVICE_CHECK_OPTIONS = {
      timestamp: 'd',
      hostname: 'h',
      message: 'm',
    }

    include MonitorMixin

    attr_reader :host, :port
    attr_accessor :implementation

    def initialize(server = nil, implementation = nil)
      super()
      self.server = server || "localhost:8125"
      self.implementation = (implementation || DEFAULT_IMPLEMENTATION).to_sym
    end

    def collect_metric(metric)
      unless implementation_supports_metric_type?(metric.type)
        StatsD.logger.warn("[StatsD] Metric type #{metric.type.inspect} not supported on #{implementation} implementation.")
        return false
      end

      if metric.sample_rate < 1.0 && rand > metric.sample_rate
        return false
      end

      write_packet(generate_packet(metric))
    end

    def implementation_supports_metric_type?(type)
      case type
        when :h;  implementation == :datadog
        when :_e; implementation == :datadog
        when :_sc; implementation == :datadog
        when :kv; implementation == :statsite
        else true
      end
    end

    def server=(connection_string)
      self.host, port = connection_string.split(':', 2)
      self.port = port.to_i
      invalidate_socket
    end

    def host=(host)
      @host = host
      invalidate_socket
    end

    def port=(port)
      @port = port
      invalidate_socket
    end

    def socket
      if @socket.nil?
        @socket = UDPSocket.new
        @socket.connect(host, port)
      end
      @socket
    end

    def generate_packet(metric)
      command = ""
      if metric.type == :_e
        escaped_title = metric.name.tr('\n', '\\n')
        escaped_text = metric.value.tr('\n', '\\n')

        command << "_e{#{escaped_title.size},#{escaped_text.size}}:#{escaped_title}|#{escaped_text}"
        command << generate_metadata(metric, EVENT_OPTIONS)
      elsif metric.type == :_sc
        command << "_sc|#{metric.name}|#{metric.value}"
        command << generate_metadata(metric, SERVICE_CHECK_OPTIONS)
      else
        command = "#{metric.name}:#{metric.value}|#{metric.type}"
      end
      command << "|@#{metric.sample_rate}" if metric.sample_rate < 1 || (implementation == :statsite && metric.sample_rate > 1)
      if metric.tags
        if tags_supported?
          command << "|##{metric.tags.join(',')}"
        else
          StatsD.logger.warn("[StatsD] Tags are only supported on Datadog implementation.")
        end
      end

      command << "\n" if implementation == :statsite
      command
    end

    def tags_supported?
      implementation == :datadog
    end

    def write_packet(command)
      synchronize do
        socket.send(command, 0) > 0
      end
    rescue ThreadError => e
      # In cases where a TERM or KILL signal has been sent, and we send stats as
      # part of a signal handler, locks cannot be acquired, so we do our best
      # to try and send the command without a lock.
      socket.send(command, 0) > 0
    rescue SocketError, IOError, SystemCallError, Errno::ECONNREFUSED => e
      StatsD.logger.error "[StatsD] #{e.class.name}: #{e.message}"
    end

    def invalidate_socket
      @socket = nil
    end

    private

    def generate_metadata(metric, options)
      (metric.metadata.keys & options.keys).map do |key|
        "|#{options[key]}:#{metric.metadata[key]}"
      end.join
    end
    
  end
end

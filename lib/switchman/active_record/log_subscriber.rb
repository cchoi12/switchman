module Switchman
  module ActiveRecord
    module LogSubscriber
      # sadly, have to completely replace this
      def sql(event)
        self.class.runtime += event.duration
        return unless logger.debug?

        payload = event.payload

        return if ::ActiveRecord::LogSubscriber::IGNORE_PAYLOAD_NAMES.include?(payload[:name])

        name  = "#{payload[:name]} (#{event.duration.round(1)}ms)"
        name  = "CACHE #{name}" if payload[:cached]
        sql   = payload[:sql].squeeze(' '.freeze)
        binds = nil
        shard = payload[:shard]
        shard = "  [#{shard[:database_server_id]}:#{shard[:id]} #{shard[:env]}]" if shard

        unless (payload[:binds] || []).empty?
          use_old_format = (::Rails.version < '5.1.5')
          args = use_old_format ?
            [payload[:binds], payload[:type_casted_binds]] :
            [payload[:type_casted_binds]]
          casted_params = type_casted_binds(*args)
          binds = "  " + payload[:binds].zip(casted_params).map { |attr, value|
            render_bind(attr, value)
          }.inspect
        end

        name = colorize_payload_name(name, payload[:name])
        sql  = color(sql, sql_color(sql), true)

        debug "  #{name}  #{sql}#{binds}#{shard}"
      end
    end
  end
end

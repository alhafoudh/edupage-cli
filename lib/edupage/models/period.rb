module Edupage
  module Models
    # One slot in the daily bell schedule ("2nd period, 08:45-09:30").
    class Period < Model
      attribute :name
      attribute :short
      attribute :start_time, "starttime"
      attribute :end_time, "endtime"

      def to_s = "#{name}. #{start_time}-#{end_time}"
    end
  end
end

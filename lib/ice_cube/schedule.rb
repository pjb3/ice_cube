module IceCube

  class Schedule

    attr_reader :rdates, :exdates, :start_date, :duration, :end_time
    alias :start_time :start_date
    
    def initialize(start_date, options = {})
      @rrule_occurrence_heads = []
      @exrule_occurrence_heads = []
      @rdates = []
      @exdates = []
      @start_date = start_date
      raise ArgumentError.new('Duration cannot be negative') if options[:duration] && options[:duration] < 0
      @duration = options[:duration]
      raise ArgumentError.new('Start time must be before end time') if options[:end_time] && options[:end_time] < @start_date
      @end_time = options[:end_time]
    end

    # Convert the schedule to a hash, reverse of Schedule.from_hash
    def to_hash
      hash = Hash.new
      hash[:start_date] = @start_date
      hash[:rrules] = @rrule_occurrence_heads.map { |rr| rr.rule.to_hash }
      hash[:exrules] = @exrule_occurrence_heads.map { |ex| ex.rule.to_hash }
      hash[:rdates] = @rdates
      hash[:exdates] = @exdates
      hash[:duration] = @duration
      hash[:end_time] = @end_time
      hash
    end

    # Convert the schedule to yaml, reverse of Schedule.from_yaml
    def to_yaml
      hash = to_hash
      hash[:start_date] = TimeUtil.serializable_time(hash[:start_date])
      hash[:rdates] = hash[:rdates].map { |t| TimeUtil.serializable_time(t) }
      hash[:exdates] = hash[:exdates].map { |t| TimeUtil.serializable_time(t) }
      hash[:end_time] = TimeUtil.serializable_time(hash[:end_time])
      hash.to_yaml
    end

    # Create a schedule from a hash created by instance.to_hash
    def self.from_hash(hash)
      options = {}
      options[:duration] = hash[:duration] if hash.has_key?(:duration)
      options[:end_time] = hash[:end_time] if hash.has_key?(:end_time)
      schedule = Schedule.new(hash[:start_date], options)
      hash[:rrules].each { |rr| schedule.add_recurrence_rule Rule.from_hash(rr) }
      hash[:exrules].each { |ex| schedule.add_exception_rule Rule.from_hash(ex) }
      hash[:rdates].each { |rd| schedule.add_recurrence_date rd }
      hash[:exdates].each { |ed| schedule.add_exception_date ed }
      schedule
    end

    # Create a schedule from a yaml string created by instance.to_yaml
    def self.from_yaml(str)
      from_hash(YAML::load(str))
    end

    TIME_FORMAT = '%B %e, %Y'
    SEPARATOR = ' / '
    
    # use with caution
    # incomplete and not entirely tested - no time representation in dates
    # there's a lot that can happen here
    def to_s
      representation = ''
      inc_dates = (@rdates - @exdates).uniq
      if inc_dates && !inc_dates.empty?
        representation << inc_dates.sort.map { |d| d.strftime(TIME_FORMAT) }.join(SEPARATOR)
      end
      if @rrule_occurrence_heads && !@rrule_occurrence_heads.empty?
        representation << SEPARATOR unless representation.empty?
        representation << @rrule_occurrence_heads.map{ |r| r.rule.to_s }.join(SEPARATOR)
      end
      if @exrule_occurrence_heads && !@exrule_occurrence_heads.empty?
        representation << SEPARATOR unless representation.empty?
        representation << @exrule_occurrence_heads.map { |r| 'not ' << r.to_s }.join(SEPARATOR)
      end
      if @exdates && !@exdates.empty?
        representation << SEPARATOR unless representation.empty?
        representation << @exdates.uniq.sort.map { |d| 'not on ' << d.strftime(TIME_FORMAT) }.join(SEPARATOR)
      end
      if @end_time
        representation << "until #{end_time.strftime(TIME_FORMAT)}"
      end
      representation
    end

    def occurring_at?(time)
      return false if @exdates.include?(time)
      return true if @rdates.include?(time)
      return false if any_occurring_at?(@exrule_occurrence_heads, time)
      any_occurring_at?(@rrule_occurrence_heads, time)
    end

    # Determine whether a given time adheres to the ruleset of this schedule.
    def occurs_at?(date)
      return false if @end_time && date > @end_time
      dates = occurrences(date)
      dates.last == date
    end
    
    # Determine whether a given date appears in the times returned by the schedule
    # Required activeSupport
    def occurs_on?(date)      
      time = date.to_time
      return false if @end_time && time > @end_time
      occurrences_between(time.beginning_of_day, time.end_of_day).any?
    end
        
    # Return all possible occurrences 
    # In order to make this call, all rules in the schedule must have
    # either an until date or an occurrence count
    def all_occurrences
      find_occurrences { |head| head.all_occurrences }
    end
    
    # Find all occurrences until a certain date
    def occurrences(end_date)
      end_date = @end_time if @end_time && @end_time < end_date
      find_occurrences { |head| head.upto(end_date) }
    end

    # Retrieve the first (n) occurrences of the schedule.  May return less than
    # n results, if the rules end before n results are reached.
    def first(n = 1)
      dates = find_occurrences { |head| head.first(n) }
      dates.slice(0, n)
    end
             
    # Add a rule of any type as an recurrence in this schedule
    def add_recurrence_rule(rule)
      raise ArgumentError.new('Argument must be a valid rule') unless rule.class < Rule
      @rrule_occurrence_heads << RuleOccurrence.new(rule, @start_date, @end_time)
    end

    def rrules
      @rrule_occurrence_heads.map { |h| h.rule }
    end

    # Add a rule of any type as an exception to this schedule
    def add_exception_rule(rule)
      raise ArgumentError.new('Argument must be a valid rule') unless rule.class < Rule
      @exrule_occurrence_heads << RuleOccurrence.new(rule, @start_date, @end_time)
    end

    def exrules 
      @exrule_occurrence_heads.map { |h| h.rule }
    end

    # Add an individual date to this schedule
    def add_recurrence_date(date)
      @rdates << date unless date.nil?
    end

    # Add an individual date exception to this schedule
    def add_exception_date(date)
      @exdates << date unless date.nil?
    end   

    def occurrences_between(begin_time, end_time)
      # adjust to the propert end date
      end_time = @end_time if @end_time && @end_time < end_time
      # collect the occurrences
      exclude_dates, include_dates = Set.new(@exdates), SortedSet.new(@rdates)
      @rrule_occurrence_heads.each do |rrule_occurrence_head|
        include_dates.merge(rrule_occurrence_head.between(begin_time, end_time))
      end
      @exrule_occurrence_heads.each do |exrule_occurrence_head|
        exclude_dates.merge(exrule_occurrence_head.between(begin_time, end_time))
      end
      # reject all of the ones outside of the range
      include_dates.reject! { |date| exclude_dates.include?(date) || date < begin_time || date > end_time }
      include_dates.to_a
    end
    
    private

    # tell if, from a list of rule_occurrence heads, a certain time is occurring
    def any_occurring_at?(what, time)
      return false if @start_time && time < @start_time
      what.any? do |occurrence_head|
        # time is less than now and duration is less than that distance
        possibilities = occurrence_head.between(@start_date, time)
        possibilities.any? do |possibility|
          possibility + (@duration || 0) >= time
        end
      end
    end
      
    # Find all occurrences (following rules and exceptions) from the schedule's start date to end_date.
    # Use custom methods to say when to end
    def find_occurrences
      exclude_dates, include_dates = Set.new(@exdates), SortedSet.new(@rdates)
      # walk through each rule, adding it to dates
      @rrule_occurrence_heads.each do |rrule_occurrence_head|
        include_dates.merge(yield(rrule_occurrence_head))
      end
      # walk through each exrule, removing it from dates
      @exrule_occurrence_heads.each do |exrule_occurrence_head|
        exclude_dates.merge(yield(exrule_occurrence_head))
      end
      #return a unique list of dates
      include_dates.reject! { |date| exclude_dates.include?(date) }
      include_dates.to_a
    end
   
  end

end

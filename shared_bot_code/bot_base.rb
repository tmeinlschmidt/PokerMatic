require 'rubygems'
require 'pp'
require 'timeout'
require 'spire_io'

config_file_location = File.expand_path("#{File.dirname(__FILE__)}/../config.rb")
require config_file_location if File.exists?(config_file_location)
require File.expand_path("#{File.dirname(__FILE__)}/../utils/mutex_two.rb")
require File.expand_path("#{File.dirname(__FILE__)}/../poker/poker.rb")

if !defined?(USE_ENCRYPTION) or USE_ENCRYPTION
	require 'openpgp'
	require 'openssl'
else
	USE_ENCRYPTION = false
end

#The PokerBotBase class contains all the code needed to create PokerServer clients
#This class should be extended to create your own client; it will not work on its own
#The only method absolutely needed for your client is ask_for_move, which is called every
#time it is the client's turn to make a move.  It is passed a GameState object, which
#is a representation of the current state of the game
#NOTE: Make sure to call super on your subclass's initialize method
class PokerBotBase
	attr_accessor :player_id, :mutex, :name

	def initialize(discovery_url = nil, discovery_capability = nil)
		@mutex = MutexTwo.new
		@player_id = nil
		@spire = Spire.new("http://build.spire.io")
		@table_channel = nil
		@hand_hash = {}
		discovery_url ||= get_discovery_url
		discovery_capability ||= get_discovery_capability
		d_sub = new_sub(discovery_url, discovery_capability)
		@discovery = JSON.parse(d_sub.listen.last)
	end
	
	def get_discovery_url
		if defined?(DISCOVERY_URL)
			DISCOVERY_URL
		else
			puts "Discovery url?"
			gets.chomp
		end
	end
	
	def get_discovery_capability
		if defined?(DISCOVERY_CAPABILITY)
			DISCOVERY_CAPABILITY
		else
			puts "Discovery capability?"
			gets.chomp
		end
	end

	#Registers a user with the given name and waits for the server to respond with the created user
	def create_user(name)
		@mutex.synchronize do
			@name = name
			@reg_response = new_sub(@discovery['registration_response']['url'],
				@discovery['registration_response']['capability'])
			@command_id = rand(99999999)
			@reg_response.last = (Time.now.to_i * 1000) - 5
			@reg_response.add_listener('reg_response') {|m| user_created(m)}
			@reg_response.start_listening
			@create_player_channel = new_channel(@discovery['registration']['url'],
				@discovery['registration']['capability'])
			hsh = {'name' => name, 'id' => @command_id}
			if USE_ENCRYPTION
				@encryption_keys = OpenSSL::PKey::RSA.generate(1024)
				hsh['public_key'] = @encryption_keys.public_key
			end
			@create_player_channel.publish(hsh.to_json)
		end
		wait_for_player_to_be_created
	end

	def wait_for_player_to_be_created
		while true
			should_exit = false
			@mutex.synchronize do
				should_exit = !!@player_id
			end
			break if should_exit
			sleep 1
		end
		@reg_response.stop_listening if @reg_response
	end

	#Callback for whenever a user is created.  If the created user was created by this client,
	#set the current user to the newly created user
	def user_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @command_id
			@mutex.synchronize do
				if USE_ENCRYPTION
					cap = @encryption_keys.private_decrypt(OpenPGP.dearmor(resp['encrypted_capability']))
					resp_cap = @encryption_keys.private_decrypt(OpenPGP.dearmor(resp['encrypted_response_capability']))
				else
					cap = resp['capability']
					resp_cap = resp['response_capability']
				end
				@player_channel = new_channel(resp['url'], cap)
				@player_updates = new_sub(resp['response_url'], resp_cap)
				@player_updates.add_listener('player_update') {|mess| table_update_proxy(mess)}
				@player_updates.start_listening
				@player_id = resp['player_id']
			end
		end
	end

	def subscribe_to_table(parsed)
		puts "Subscribing to table with instructions:"
		pp parsed
		@table_channel.stop_listening if @table_channel
		@table_channel = new_sub(parsed['url'], parsed['capability'])
		@table_channel.last = ((Time.now.to_i - 5) * 1000)
		@table_channel.add_listener('table_update') {|mess| table_update_proxy(mess)}
		@table_channel.start_listening
		puts "Subscribed"
	end

	#Joins a table described by data
	# Data should include an 'id', 'url', 'capability', and 'name'
	def join_specific_table(data)
		@player_channel.publish({'table_id' => data['id'], 'command' => 'join_table'}.to_json)
	end

	def join_specific_tournament(data)
		@player_channel.publish({'tournament_id' => data['id'], 'command' => 'join_tournament'}.to_json)
	end

	#Listener for table updates, proxys the requests to the correct handler
	def table_update_proxy(m)
		parsed = JSON.parse(m)
		case parsed['type']
			when 'game_state' then game_state_update(parsed)
			when 'winner' then winner_update(parsed)
			when 'error' then invalid_move(parsed)
			when 'table_subscription' then subscribe_to_table(parsed)
		end
	end

	def decrypt_hand(encrypted_hand)
		encrypted_hand.map do |card|
			ret = {}
			card.each do |key, value|
				ret[key] = @encryption_keys.private_decrypt(OpenPGP.dearmor(value))
				ret[key] = ret[key].to_i if key == "value"
			end
			ret
		end
	end

	#Called whenever a new game state comes in
	#Creates a GameState object, waits for the hand information to come in,
	#and calls ask_for_move if it is the clients turn
	#Also calls display_game_state if the client has defined it
	def game_state_update(parsed_state)
		game_state = nil
		@mutex.synchronize do
			if parsed_state['player_data'] and my_data = parsed_state['player_data'][@player_id.to_s]
				hand = decrypt_hand(my_data['hand'])
				@hand_hash[parsed_state['hand_number']] = hand
				@seat_number = my_data['seat_number']
				@bankroll = my_data['player']['bankroll']
			else
				hand = @hand_hash[parsed_state['hand_number']]
			end
			game_state = GameState.new(parsed_state, @player_id, hand)
		end
		@mutex.synchronize do
			self.display_game_state(game_state) if self.respond_to?(:display_game_state)
			if game_state.is_acting_player? and game_state.hand
				begin
					#Timeout.timeout(game_state.timelimit) do
						move = ask_for_move(game_state)
						move = 'fold' unless move
						@player_channel.publish({'table_id' => game_state.table_id,
						'command' => 'action', 'action' => move}.to_json)
					#end
				#rescue Timeout::Error
					#puts "Took too long to make a move, folding"
				rescue
					puts "Error: #{$!.inspect}"
					pp $!.backtrace
				end
			end
		end
	end

	#Called when the client makes an invalid move
	#Can be overridden by subclasses to handle errors
	def invalid_move(data)
		@mutex.synchronize do
			puts "Invalid move: #{data['message']}"
		end
	end

	def winner_update(parsed)
		#Should be defined by parent class
	end

	#Callback for a table being created.. joins the table if we created it
	def my_table_created(m)
		resp = JSON.parse(m)
		if resp['command_id'] == @player_id
			join_specific_table(resp)
		end
	end

	#Creates a table and joins it
	# @param [String] name Name for the table
	# @param [String] min_players Minimum players the table requires before starting game
	# @param [String] blinds Starting small blind for the table
	def create_table(name, min_players = 2, blinds = 1)
		raise "No player yet!" unless @player_id
		@table_response = new_sub(@discovery['tables']['url'],
				@discovery['tables']['capability'])
		@create_table_channel = new_channel(@discovery['create_table']['url'],
				@discovery['create_table']['capability'])
		@table_response.last = (Time.now.to_i * 1000) - 5
		@table_response.add_listener('table_response') {|m| my_table_created(m)}
		@table_response.start_listening
		@create_table_channel.publish({'name' => name, 'id' => @player_id,
			'min_players' => min_players, 'blinds' => blinds}.to_json)
	end

	# Get a listing of all available tables
	# @return [Array] An array of hashes describing each table
	def get_all_tables
		tc = new_sub(@discovery['tables']['url'], @discovery['tables']['capability'])
		tc.listen.map {|x| JSON.parse(x) rescue nil}.compact
	end

	# Get a listing of all available tables
	# @return [Array] An array of hashes describing each table
	def get_all_tournaments
		tc = new_sub(@discovery['tournaments']['url'], @discovery['tournaments']['capability'])
		tc.listen.map {|x| JSON.parse(x) rescue nil}.compact
	end

	#Displays all available tables and prompts to join one
	#Uses gets, so requires CLI input
	def join_table
		raise "No player yet!" unless @player_id
		join_specific_table(ask_to_choose_table)
	end

	def join_tournament
		raise "No player yet!" unless @player_id
		join_specific_tournament(ask_to_choose_tournament)
	end

	def ask_to_choose_table
		#get all the possible tables
		all_tables = get_all_tables
		hsh_map = {}
		num = 0
		all_tables.each do |table|
			num += 1
			hsh_map[num] = table
			puts "Table #{num}: #{table['name']} Blinds #{table['blinds']} Min Players #{table['min_players']}"
		end
		puts "Join which table?"
		tnum = gets.chomp.to_i
		hsh_map[tnum]
	end

	def ask_to_choose_tournament
		#get all the possible tables
		all_tourneys = get_all_tournaments
		hsh_map = {}
		num = 0
		all_tourneys.each do |tourney|
			num += 1
			hsh_map[num] = tourney
			puts "Tourney #{num}: #{tourney['name']} Starting at #{Time.at(tourney['starting_time'])}"
		end
		puts "Join which tourney?"
		tnum = gets.chomp.to_i
		hsh_map[tnum]
	end

	def check_fold(game_state)
		game_state.available_moves['check'] ? 'check' : 'fold'
	end

	def ask_for_move(game_state)
		raise "Subclass does not define ask_for_move!"
	end

	def new_sub(url, capability)
		Spire::Subscription.new(@spire,
			{'capability' => capability, 'url' => url})
	end
	
	def new_channel(url, capability)
		Spire::Channel.new(@spire,
			{'capability' => capability, 'url' => url})
	end

	#A class representing the current state of the game
	class GameState
		attr_accessor :hand, :player_id

		def initialize(state, my_player_id, my_hand = nil)
			@state_hash = state
			@player_id = my_player_id
			@hand = my_hand
		end
		
		#Access the state hash or sub hash directly
		def [](key)
			self.send(key.to_sym)
		end

		def tournament?
			!!@state_hash['tournament']
		end

		#Uses method missing to access the underlying state hash
		def method_missing(meth, *args)
			if @state_hash.has_key?(meth.to_s)
				@state_hash[meth.to_s]
			elsif @state_hash['state'].has_key?(meth.to_s)
				@state_hash['state'][meth.to_s]
			else
				super
			end
		end

		def respond_to?(meth)
			(@state_hash.has_key?(meth.to_s) or @state_hash['state'].has_key?(meth.to_s)) ? true : super
		end

		#Sets the clients hand for the given game state.  When the hand is returned by the server
		#before the game state is, the hand is set during initialization, otherwise it is set
		#at a later time
		def set_hand(hand)
			@hand = hand
		end
		
		# returns true if the client is in the hand
		def in_this_hand?
			@state_hash['state']['players'].any? {|p| p['id'] == @player_id}
		end

		def still_in_hand?(player_id)
			@state_hash['state']['players_in_hand'].include?(player_id.to_i)
		end

		# returns true if it is the clients turn to act
		def is_acting_player?
			@_iap ||= @state_hash['state']['acting_player']['id'] == @player_id
		end
		
		def number_of_players_in_hand
			@_npih ||= @state_hash['state']['players_in_hand'].size
		end
		
		#Returns the position of the acting player compared to the button (0 is button, 1 is the spot before the button)
		def position
			return 0 if self.button == self.acting_seat
			spots = 1
			current_spot = self.acting_seat - 1
			self.number_of_players_in_hand.size.times do
				current_spot = @state_hash['state']['players'].size - 1 if current_spot < 0
				return spots if current_spot == self.acting_seat
				spots += 1 if still_in_hand?(@state_hash['state']['players'][current_spot]['id'])
				current_spot -= 1
			end
		end
	end #class GameState
end #Class PokerBotBase
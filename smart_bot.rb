#!/usr/bin/env ruby
require 'rubygems'
require 'pp'
require 'spire_io'
require 'client_base'
require 'poker'

class SmartBot < PokerClientBase

	def initialize
		super
		@aggressiveness = rand(4) + 1
	end

	def starting_hand_value(hand)
		hand = hand.dup
		hand.each {|x| x['sort_val'] = x['value'] == 1 ? 14 : x['value'] }
		hand.sort! {|x, y| y['sort_val'] <=> x['sort_val']}
		top_val = hand.first['sort_val']
		base_val = case top_val
			when 14 then 10
			when 13 then 8
			when 12 then 7
			when 11 then 6
			else top_val / 2.0
		end
		if hand.first['value'] == hand.last['value']
			if base_val == 2.5
				base_val = 3 
			end
			base_val *= 2
			base_val = 5 if base_val < 5
		else
			base_val += 2 if hand.first['suit'] == hand.last['suit']
			diff = hand.first['sort_val'] - hand.last['sort_val']
			if diff == 1
				base_val += 1 if hand.first['sort_val'] < 12 #lower than a queen
			elsif diff == 2
				base_val -= 1
			elsif diff == 3
				base_val -= 2
			elsif diff == 4
				base_val -= 4
			else
				base_val -= 5
			end
		end
		base_val
	end

	def ask_for_move(game_state)
		puts "Move for #{self.name}"
		puts "My aggressiveness: #{@aggressiveness}" 
		game_state.hand.each {|h| puts h['string']}
		case game_state.phase
			when 1 then pre_flop_move(game_state)
			when 2 then flop_move(game_state)
			when 3 then turn_move(game_state)
			when 4 then river_move(game_state)
		end
	end

	def pre_flop_move(game_state)
		call_amount = game_state.available_moves['call'] || 0
		shv = starting_hand_value(game_state.hand)
		puts "Pre flop hand value is #{shv} with a call amount of #{call_amount}"
		if shv < 10 
			if call_amount > 0
				pih = game_state.number_of_players_in_hand
				return 'fold' unless rand(pih * (game_state.position + 1) * call_amount) < shv * @aggressiveness
				return rand(shv + 5) < 5 ? 'call' : game_state.available_moves['bet'] * (rand(4) + 1) * @aggressiveness
			else
				return rand(shv + 5) < 7 ? 'check' : game_state.available_moves['bet'] * (rand(3) + 1) * @aggressiveness
			end
		else
			if call_amount > (@bankroll / 4)
				return 'fold' if rand(20) > shv * @aggressiveness
			end
			return rand(shv + 10) < 10 ? 'call' : game_state.available_moves['bet'] * (rand(shv - 9) + 1) * @aggressiveness
		end
	end

	def turn_move(game_state)
		flop_move(game_state, 2)
	end

	def river_move(game_state)
		flop_move(game_state, 3)
	end

	def flop_move(game_state, mult = 1)
		call_amount = game_state.available_moves['call'] || 0
		shv = starting_hand_value(game_state.hand)
		hand_val = PokerMatic::HandComparison.new(nil, nil,
			PokerMatic::Card.create(game_state.board)).best_hand(PokerMatic::Card.create(game_state.hand))[:rank] - 
			PokerMatic::HandComparison.new(nil, nil,
			PokerMatic::Card.create(game_state.board)).best_hand([])[:rank]
		total_val = shv * ((hand_val + 1) ** 2)
		min_bet = game_state.available_moves['bet']
		pot_odds = game_state.pot / (call_amount.to_f + 1)
		puts "Flop shv #{shv} hand val #{hand_val} total val #{total_val} and call amount #{call_amount} pot is #{game_state.pot} with pot odds #{pot_odds}"
		if call_amount == 0
			return 'check' if rand(total_val * @aggressiveness) < 8
			return min_bet * (min_rand_from(total_val, 5) + 1) * mult * @aggressiveness
		end
		if hand_val == 0
			return 'fold' if rand(@aggressiveness * shv * pot_odds + 10) < 10
			return rand(shv * pot_odds) < 10 ? 'call' : min_bet * (min_rand_from(shv * pot_odds, 20) + 1) * mult * @aggressiveness
		end
		return 'fold' if pot_odds < 0.5 and rand(3) > 0 and hand_val < 2
		return 'fold' if rand(@aggressiveness * total_val * pot_odds + 5) < 5
		rand(total_val * pot_odds) < 10 ? 'call' : min_bet * (min_rand_from(total_val * pot_odds, 10) + 1) * mult * @aggressiveness
	end

	def min_rand_from(total_val, num_times)
		num_times.times.map { rand(total_val)}.min
	end

	def pick_move(weights)
		total = weights.values.inject(0) {|i, x| i + x}
		curr_tot = 0
		rval = rand(total)
		weights.each do |key, value|
			curr_tot += value
			return key if rval < curr_tot
		end
	end
end

if $PROGRAM_NAME == __FILE__
	client = SmartBot.new
	puts "User name?"
	name = gets.chomp
	client.create_user(name)
	puts "Join a room or create a new one? 'join' or name of room"
	if 'join' == (choice = gets.chomp)
		client.join_table
	else
		puts "Number of players at the table?"
		num = gets.chomp.to_i
		client.create_table(choice, num)
	end
	while true
		sleep 1000
	end
end
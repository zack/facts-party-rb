# rubocop:disable Metrics
# rubocop:disable Layout/LineLength
# rubocop:disable Style/Next
# rubocop:disable Style/WordArray

require 'csv'
require 'pry'
require 'sqlite3'


# idempotent
def create_db
  db = SQLite3::Database.open 'party.db'
  db.results_as_hash = true
  db.execute 'CREATE TABLE IF NOT EXISTS players(name TEXT unique)'
  db.execute 'CREATE TABLE IF NOT EXISTS statements(player_id INT, statement TEXT unique, answer INT)'
  db.execute 'CREATE TABLE IF NOT EXISTS guesses(player_id INT, statement_id INT, guess INT)'
  db
end

# idempotent
def seed_db(db)
  CSV.foreach('statements.csv') do |row|
    player = row[0]
    statement = row[1]
    answer = row[2] == 'TRUE' ? 1 : 0

    # create the player row if it doesn't already exist
    db.execute 'INSERT OR IGNORE INTO players (name) VALUES (?)', player

    # get the id of the player
    player_id = (db.execute 'SELECT rowid FROM players WHERE name=?', player)[0][0]
    # create the statement row
    db.execute 'INSERT OR IGNORE INTO statements (player_id, statement, answer) VALUES (?, ?, ?)', player_id, statement, answer
  end
end

def insert_guess(db, player_id, statement_id, guess)
  # delete any existing guess row
  db.execute 'DELETE FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement_id

  # create the guess row
  db.execute 'INSERT INTO guesses (player_id, statement_id, guess) VALUES (?, ?, ?)', player_id, statement_id, guess
end

def print_player_statuses(db, guesses)
  players = db.execute 'SELECT rowid,* from players'

  statement_count = (db.execute 'SELECT COUNT(*) from statements')[0][0]

  players.each do |player|
    # get the id of the player
    player_id_hash = db.execute 'SELECT rowid FROM players WHERE name=?', player['name']
    player_id = player_id_hash[0]['rowid']

    guesses_submitted = (db.execute 'SELECT COUNT(*) FROM guesses WHERE player_id=?', player_id)[0][0]

    guess_string = if guesses_submitted == statement_count
                     'ALL'
                   elsif guesses_submitted.zero?
                     'NONE'
                   else
                     guesses_submitted.to_s
                   end

    if guesses
      puts "#{player['rowid'].to_s.rjust(2, ' ')}: #{player['name'].ljust(20, ' ')}: #{guess_string}"
    else
      puts "#{player['rowid'].to_s.rjust(2, ' ')}: #{player['name'].ljust(20, ' ')}"
    end
  end
end

def print_players_with_ids(db)
  puts 'Players:'
  players = db.execute 'SELECT * from players'
  players.each do |player|
    # get the id of the player
    player_id_hash = db.execute 'SELECT rowid FROM players WHERE name=?', player['name']
    player_id = player_id_hash[0]['rowid']
    puts "#{player_id.to_s.rjust(2, ' ')}: #{player['name']}"
  end
end

def submit_player_guesses(db)
  # we will use this later
  statement_count = (db.execute 'SELECT COUNT(*) from statements')[0][0]

  loop do
    print_player_statuses(db, true)

    player_id = 0
    while player_id.zero?
      print 'Enter a player id (0 to stop): '
      id = gets.chomp.to_i

      return if id.zero?

      player_exists = (db.execute 'SELECT COUNT(*) FROM players WHERE rowid=?', id)[0][0] == 1
      player_id = id if player_exists
    end

    # clear existing guesses for this player
    db.execute 'DELETE FROM guesses WHERE player_id=?', player_id

    player_name = (db.execute 'SELECT name FROM players WHERE rowid=?', player_id)[0][0]
    loop do
      print "Enter guesses for #{player_name}: "
      guesses = gets.chomp
      if guesses.length == statement_count && guesses.gsub(/[01]/, '') == ''
        guesses.split('').each_with_index do |guess, index|
          insert_guess(db, player_id, index + 1, guess)
        end
        break
      end
    end
  end
end

def mock_player_guesses(db)
  players = db.execute 'SELECT rowid,* FROM players'
  statements = db.execute 'SELECT rowid,* FROM statements'

  players.each do |player|
    statements.each do |statement|
      insert_guess(db, player['rowid'], statement['rowid'], [0,1].sample)
    end
  end
end

def generate_player_scoresheet(db, player_id)
  player = (db.execute 'SELECT * FROM players WHERE rowid=?', player_id)[0]
  statements = db.execute 'SELECT rowid,* FROM statements'
  player_statements = db.execute 'SELECT rowid,* FROM statements WHERE player_id=?', player_id

  score_from_guesses = 0
  score_from_trickery = 0

  filename = "#{player['name'].gsub(/' '/, '').downcase}.txt"
  File.delete(filename) if File.exist?(filename)
  File.open(filename, 'w') do |f|
    f.puts("Scoresheet for player: #{player['name']}")
    f.puts

    f.puts('=== YOUR GUESSES ===')
    f.puts

    statements.each do |statement|
      source = (db.execute 'SELECT name FROM players WHERE rowid=?', statement['player_id'])[0]
      answer = statement['answer'] == 1 ? 'TRUE' : 'FALSE'
      raw_guess = (db.execute 'SELECT guess FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement['rowid'])[0][0]
      guess = raw_guess == 1 ? 'TRUE' : 'FALSE'
      score_from_guesses += 1 if guess == answer
      submitter_name = "#{source['name'].split(' ')[0]} #{source['name'].split[1][0]}"

      f.puts("#{statement['rowid'].to_s.rjust(2, '0')}: #{statement['statement']}")
      f.write("    Submitted by #{submitter_name}. You said #{guess}. The answer was #{answer}.")
      f.puts
      f.puts
    end

    f.puts('=== YOUR SUBMISSIONS ===')
    f.puts

    player_statements.each do |statement|
      wrong_guesses = (db.execute 'SELECT COUNT(*) FROM guesses WHERE statement_id=? AND guess!=?', statement['rowid'], statement['answer'])[0][0]
      score_from_trickery += wrong_guesses.to_i
      answer = statement['answer'] == '1' ? 'TRUE' : 'FALSE'

      f.puts("#{statement['rowid'].to_s.rjust(2, '0')}: #{statement['statement']}")
      f.puts("    Answer was #{answer}. You tricked: #{wrong_guesses} players")
      f.puts
    end

    f.puts('=== SCORE ===')
    f.puts
    f.puts("Points from guesses: #{score_from_guesses} (#{get_score_from_guesses(db, player_id)})")
    f.puts("Points from trickery: #{score_from_trickery} (#{get_score_from_trickery(db, player_id)})")
    f.puts("Total score: #{score_from_guesses + score_from_trickery}")
  end
end

def generate_game_summary_scoresheet(db)
  name_length = (db.execute 'SELECT LENGTH(name) FROM players ORDER BY LENGTH(name) DESC LIMIT 1')[0][0]
  players = db.execute 'SELECT rowid,* FROM players '

  scores = []

  players.each do |player|
    player_name = player['name']
    score_from_guesses = get_score_from_guesses(db, player['rowid'])
    score_from_trickery = get_score_from_trickery(db, player['rowid'])
    total_score = score_from_guesses + score_from_trickery
    player_hash = {
      player_name: player_name,
      score_from_guesses: score_from_guesses,
      score_from_trickery: score_from_trickery,
      total_score: total_score
    }
    scores.push(player_hash)
  end

  sorted_scores = scores.sort_by { |score| score[:player_name] }
  top_scorers = scores.sort_by { |score| score[:total_score] }.reverse[0, 3]
  top_guessers = scores.sort_by { |score| score[:score_from_guesses] }.reverse[0, 3]
  top_trickers = scores.sort_by { |score| score[:score_from_trickery] }.reverse[0, 3]

  File.delete('scoresheet.txt') if File.exist?('scoresheet.txt')
  File.open('scoresheet.txt', 'w') do |f|
    f.puts('TOP SCORERS:')
    top_scorers.each do |player|
      f.puts("#{player[:player_name].ljust(name_length, ' ')}: #{player[:total_score]}")
    end
    f.puts

    f.puts('TOP GUESSERS:')
    top_guessers.each do |player|
      f.puts("#{player[:player_name].ljust(name_length, ' ')}: #{player[:score_from_guesses]}")
    end
    f.puts

    f.puts('TOP TRICKERS:')
    top_trickers.each do |player|
      f.puts("#{player[:player_name].ljust(name_length, ' ')}: #{player[:score_from_trickery]}")
    end
    f.puts

    f.puts('ALL SCORERS:')
    f.write
    f.write('Player'.ljust(name_length, ' '))
    f.write(' | ')
    f.write('Score from guessing')
    f.write(' | ')
    f.write('Score from trickery')
    f.write(' | ')
    f.write('Total Score')
    f.puts

    sorted_scores.each do |score|
      f.write(score[:player_name].ljust(name_length, ' '))
      f.write(' | ')
      f.write(score[:score_from_guesses].to_s.rjust(19, ' '))
      f.write(' | ')
      f.write(score[:score_from_trickery].to_s.rjust(19, ' '))
      f.write(' | ')
      f.write(score[:total_score].to_s.rjust(11, ' '))
      f.puts
    end
  end
end

def generate_player_scoresheets(db)
  players = db.execute 'SELECT rowid,* from players'
  players.each do |player|
    generate_player_scoresheet(db, player['rowid'])
  end
end

def get_score_from_guesses(db, player_id)
  statements = db.execute 'SELECT rowid,* FROM statements'
  score_from_guesses = 0
  statements.each do |statement|
    guess = (db.execute 'SELECT guess FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement['rowid'])[0][0]
    score_from_guesses += 1 if guess == statement['answer']
  end
  score_from_guesses
end

def get_score_from_trickery(db, player_id)
  score_from_trickery = 0
  player_statements = db.execute 'SELECT rowid,* FROM statements WHERE player_id=?', player_id
  player_statements.each do |statement|
    wrong_guesses = (db.execute 'SELECT COUNT(*) FROM guesses WHERE statement_id=? AND guess!=?', statement['rowid'], statement['answer'])[0][0]
    score_from_trickery += wrong_guesses.to_i
  end
  score_from_trickery
end

db = create_db
seed_db(db)

loop do
  puts ''
  puts 'What do you want to do?'
  puts '1: Print player statuses'
  puts '2: Fill in player guesses'
  puts '3: Generate game summary scoresheet'
  puts '4: Generate player scoresheets'
  # puts '5: Mock player guesses'
  print '> '
  input = gets.chomp.to_i
  puts ''

  case input
  when 1
    print_player_statuses(db, true)
  when 2
    submit_player_guesses(db)
  when 3
    generate_game_summary_scoresheet(db)
  when 4
    generate_player_scoresheets(db)
  # when 5
  #   mock_player_guesses(db)
  else
    puts 'What?'
  end
end

# rubocop:enable Style/WordArray
# rubocop:enable Style/Next
# rubocop:enable Layout/LineLength
# rubocop:enable Metrics

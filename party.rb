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
  db.execute 'CREATE TABLE IF NOT EXISTS scores(player_id INT unique, guess_points INT, trick_points INT, bonus_points INT, total INT)'
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
    q = 'INSERT OR IGNORE INTO statements (player_id, statement, answer) VALUES (?, ?, ?)'
    db.execute q, player_id, statement, answer

    # seed bonus points
    db.execute 'INSERT OR IGNORE INTO scores (player_id, guess_points, trick_points, bonus_points, total) VALUES (?, 0, 0, 0, 0)', player_id
  end
end

def insert_guess(db, player_id, statement_id, guess)
  # delete any existing guess row
  db.execute 'DELETE FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement_id

  # create the guess row
  db.execute 'INSERT INTO guesses (player_id, statement_id, guess) VALUES (?, ?, ?)', player_id, statement_id, guess
end

def print_player_statuses(db)
  players = db.execute 'SELECT rowid,* from players'
  statement_count = (db.execute 'SELECT COUNT(*) from statements')[0][0]
  name_length = (db.execute 'SELECT LENGTH(name) FROM players ORDER BY LENGTH(name) DESC LIMIT 1')[0][0]

  players.each do |player|
    player_id = (db.execute 'SELECT rowid FROM players WHERE name=?', player['name'])[0]['rowid']
    guesses_submitted = (db.execute 'SELECT COUNT(*) FROM guesses WHERE player_id=?', player_id)[0][0]
    guess_string = generate_guesses_status(guesses_submitted, statement_count)

    puts "#{player['rowid'].to_s.rjust(2, ' ')}: #{player['name'].ljust(name_length + 1, ' ')}: #{guess_string}"
  end
end

def print_player_bonus_points(db)
  players = db.execute 'SELECT rowid,* from players'
  name_length = (db.execute 'SELECT LENGTH(name) FROM players ORDER BY LENGTH(name) DESC LIMIT 1')[0][0]

  players.each do |player|
    player_id = (db.execute 'SELECT rowid FROM players WHERE name=?', player['name'])[0]['rowid']
    bonus_points = (db.execute 'SELECT bonus_points FROM scores WHERE player_id=?', player_id)[0][0]

    puts "#{player['rowid'].to_s.rjust(2, ' ')}: #{player['name'].ljust(name_length + 1, ' ')}: #{bonus_points}"
  end
end

def generate_guesses_status(guesses_submitted, statement_count)
  if guesses_submitted == statement_count
    'ALL'
  elsif guesses_submitted.zero?
    'NONE'
  else
    guesses_submitted.to_s
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
  statement_count = (db.execute 'SELECT COUNT(*) from statements')[0][0]

  loop do
    print_player_statuses(db)

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

def submit_player_bonus_points(db)
  loop do
    print_player_bonus_points(db)

    player_id = 0
    while player_id.zero?
      print 'Enter a player id (0 to stop): '
      id = gets.chomp.to_i

      return if id.zero?

      player_exists = (db.execute 'SELECT COUNT(*) FROM players WHERE rowid=?', id)[0][0] == 1
      player_id = id if player_exists
    end

    player_name = (db.execute 'SELECT name FROM players WHERE rowid=?', player_id)[0][0]
    print "Enter bonus points for #{player_name}: "
    bonus_points = gets.chomp.to_i
    db.execute 'UPDATE scores SET bonus_points=? WHERE player_id=?', bonus_points, player_id
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
  player = (db.execute 'SELECT rowid,* FROM players WHERE rowid=?', player_id)[0]
  player_name = player['name']
  player_id = player['rowid']
  statements = db.execute 'SELECT rowid,* FROM statements'
  player_statements = db.execute 'SELECT rowid,* FROM statements WHERE player_id=?', player_id

  points = (db.execute 'SELECT * FROM scores WHERE player_id=?', player_id)[0]
  guess_points = points['guess_points']
  trick_points = points['trick_points']
  bonus_points = points['bonus_points']
  total_points = points['total']

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
      statement_id = statement['rowid']
      raw_guess = (
        db.execute 'SELECT guess FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement_id
      )[0][0]
      guess = raw_guess == 1 ? 'TRUE' : 'FALSE'
      submitter_name = "#{source['name'].split(' ')[0]} #{source['name'].split[1][0]}"

      f.puts("#{statement['rowid'].to_s.rjust(2, '0')}: #{statement['statement']}")
      f.write("    Submitted by #{submitter_name}. You said #{guess}. The answer was #{answer}.")
      f.puts
      f.puts
    end

    f.puts('=== YOUR SUBMISSIONS ===')
    f.puts

    player_statements.each do |statement|
      statement_id = statement['rowid']
      answer = statement['answer']
      wrong_guesses = (
        db.execute 'SELECT COUNT(*) FROM guesses WHERE statement_id=? AND guess!=?', statement_id, answer
      )[0][0]
      answer = statement['answer'] == '1' ? 'TRUE' : 'FALSE'

      f.puts("#{statement['rowid'].to_s.rjust(2, '0')}: #{statement['statement']}")
      f.puts("    Answer was #{answer}. You tricked: #{wrong_guesses} players")
      f.puts
    end

    f.puts('=== SCORE ===')
    f.puts
    f.puts("Bonus points: #{bonus_points}")
    f.puts("Points from guesses: #{guess_points}")
    f.puts("Points from trickery: #{trick_points}")
    f.puts("Total score: #{total_points}")
  end
end

def generate_scores(db)
  players = db.execute 'SELECT rowid,* FROM players '

  players.each do |player|
    player_id = player['rowid']
    bonus_points = (db.execute 'SELECT bonus_points FROM scores WHERE player_id=?', player_id)[0][0]
    guess_points = get_guess_points(db, player['rowid'])
    trick_points = get_trick_points(db, player['rowid'])
    total_score = guess_points + trick_points + bonus_points

    db.execute(
      'UPDATE scores SET guess_points=?, trick_points=?, bonus_points=?, total=? WHERE player_id=?',
      guess_points, trick_points, bonus_points, total_score, player_id
    )
  end
end

def generate_game_summary_scoresheet(db)
  name_length = (db.execute 'SELECT LENGTH(name) FROM players ORDER BY LENGTH(name) DESC LIMIT 1')[0][0] + 1

  top_scorers = db.execute(
    'SELECT name, player_id, total FROM scores INNER JOIN players ON players.rowid  = scores.player_id ORDER BY total DESC LIMIT 5'
  )
  top_guessers = db.execute(
    'SELECT name, player_id, guess_points FROM scores INNER JOIN players ON players.rowid  = scores.player_id ORDER BY guess_points DESC LIMIT 5'
  )
  top_trickers = db.execute(
    'SELECT name, player_id, trick_points FROM scores INNER JOIN players ON players.rowid  = scores.player_id ORDER BY trick_points DESC LIMIT 5'
  )
  all_scores = db.execute(
    'SELECT players.name, scores.* FROM scores INNER JOIN players ON players.rowid  = scores.player_id ORDER BY players.name ASC'
  )

  File.delete('scoresheet.txt') if File.exist?('scoresheet.txt')
  File.open('scoresheet.txt', 'w') do |f|
    f.puts('TOP SCORERS:')
    top_scorers.each do |player|
      f.puts("#{player['name'].ljust(name_length, ' ')}: #{player['total']}")
    end
    f.puts

    f.puts('TOP GUESSERS:')
    top_guessers.each do |player|
      f.puts("#{player['name'].ljust(name_length, ' ')}: #{player['guess_points']}")
    end
    f.puts

    f.puts('TOP TRICKERS:')
    top_trickers.each do |player|
      f.puts("#{player['name'].ljust(name_length, ' ')}: #{player['trick_points']}")
    end
    f.puts

    f.puts('ALL SCORERS:')
    f.write
    f.write('Player'.ljust(name_length, ' '))
    f.write('| ')
    f.write('Score from guessing')
    f.write(' | ')
    f.write('Score from trickery')
    f.write(' | ')
    f.write('Bonus Points')
    f.write(' | ')
    f.write('Total Score')
    f.puts

    all_scores.each do |score|
      f.write(score['name'].ljust(name_length, ' '))
      f.write('| ')
      f.write(score['guess_points'].to_s.rjust(19, ' '))
      f.write(' | ')
      f.write(score['trick_points'].to_s.rjust(19, ' '))
      f.write(' | ')
      f.write(score['bonus_points'].to_s.rjust(12, ' '))
      f.write(' | ')
      f.write(score['total'].to_s.rjust(11, ' '))
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

def get_guess_points(db, player_id)
  statements = db.execute 'SELECT rowid,* FROM statements'
  guess_points = 0
  statements.each do |statement|
    statement_id = statement['rowid']
    guess = (
      db.execute 'SELECT guess FROM guesses WHERE player_id=? AND statement_id=?', player_id, statement_id
    )[0][0]
    guess_points += 1 if guess == statement['answer']
  end
  guess_points
end

def get_trick_points(db, player_id)
  trick_points = 0
  player_statements = db.execute 'SELECT rowid,* FROM statements WHERE player_id=?', player_id
  player_statements.each do |statement|
    statement_id = statement['rowid']
    answer = statement['answer']
    wrong_guesses = (
      db.execute 'SELECT COUNT(*) FROM guesses WHERE statement_id=? AND guess!=?', statement_id, answer
    )[0][0]
    trick_points += wrong_guesses.to_i
  end
  trick_points
end

db = create_db
seed_db(db)

loop do
  highest_score = db.execute('SELECT total FROM scores ORDER BY total DESC LIMIT 1')[0][0]
  scores_calculated = highest_score > 0

  puts ''
  puts 'What do you want to do?'
  puts '1: Print player statuses'
  puts '2: Fill in player guesses'
  puts '3: Fill in player bonus points'
  puts '4: Calculate scores'
  if scores_calculated
    puts '5: Generate game summary scoresheet'
    puts '6: Generate player scoresheets'
  else
    puts '7: Mock player guesses'
  end
  print '> '
  input = gets.chomp.to_i
  puts ''


  case input
  when 1
    print_player_statuses(db)
  when 2
    submit_player_guesses(db)
  when 3
    submit_player_bonus_points(db)
  when 4
    generate_scores(db)
  when 5
    generate_game_summary_scoresheet(db) if scores_calculated
  when 6
    generate_player_scoresheets(db) if scores_calculated
  when 7
    mock_player_guesses(db) unless scores_calculated
  else
    puts 'What?'
  end
end

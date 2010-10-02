#!/usr/bin/env ruby

require 'rubygems'
require 'mechanize'
require 'yaml'
require 'git'

STDIN.sync = true

config = open(File.join(File.expand_path('~'), '.offlinebarf.cfg')) do |f|
	YAML.load(f)
end

g = begin
	Git.open(config['repo'])
rescue
	Git.init(config['repo'])
end
mech = WWW::Mechanize.new
mech.basic_auth(config['username'], config['password'])

events_page = mech.get('https://cccv.pentabarf.org/csv/events').body
events = events_page.split("\n").map do |event|
	event.split(',')[0]
end[1..-1]

events.each do |event_id|
	event    = mech.get("https://cccv.pentabarf.org/event/edit/#{event_id}")
	notes    = event.search('//textarea[@id="event[remark]"]').inner_html
	title    = event.search('//input[@id="event[title]"]').attr('value')
	subtitle = event.search('//input[@id="event[subtitle]"]').attr('value')
	state    = event.search('//select[@id="event[event_state]"]' \
	                        '/option[@selected]').attr('value')
	origin   = event.search('//select[@id="event[event_origin]"]' \
	                        '/option[@selected]').attr('value')
	progress = event.search('//select[@id="event[event_state_progress]"]' \
	                        '/option[@selected]').attr('value')
	lang     = event.search('//select[@id="event[language]"]' \
	                        '/option[@selected]').attr('value')
	type     = event.search('//select[@id="event[event_type]"]' \
	                        '/option[@selected]').attr('value')
	s_notes  = event.search('//textarea[@id="event[submission_notes]"]').inner_html
	abstract = event.search('//textarea[@id="event[abstract]"]').inner_html
	desc     = event.search('//textarea[@id="event[description]"]').inner_html
	puts "#{event_id} - #{state} - #{title}"

	# get event persons
	js = event.search('//script[@type="text/javascript"]')
	add_ev_person_js = js.select { |j| j.inner_html[/add_event_person/] }[0]
	rows = add_ev_person_js.inner_html.split("\n").select { |r| r[/^add_event_person/] }
	persons = rows.map do |r|
		r[/add_event_person\((.*)\)/, 1].split(',').map! do |e|
			e.gsub("'", '')
		end[2..4]
	end
	persons.each do |p|
		p[0] = event.search("//select[@id='event_person[row_id][person_id]']/option[@value='#{p[0]}']").inner_html
	end

	content =<<"XEOF"
#{event_id} - #{title}
#{subtitle}

XEOF
	persons.each do |p|
		if p[2] != 'null' then
			content += "#{p[0]}, #{p[1]} (#{p[2]})\n"
		else
			content += "#{p[0]}, #{p[1]}\n"
		end
	end
	content += "\n"
	if notes != "" then
		content += "Notes:\n#{notes}\n\n"
	end
	content +=<<"XEOF"
Origin:   #{origin}
State:    #{state}
Progress: #{progress}
Language: #{lang}
Type:     #{type}

XEOF
	if (s_notes != '') && (s_notes != "see abstract and description") then
		content += "Submission notes:\n#{s_notes}\n\n#{'-' * 80}\n"
	end

	content += "#{abstract}\n\n#{'-' * 80}\n#{desc}\n"

	filename = "#{event_id}_#{state}.txt"
	repo_filename = g.ls_files.keys.grep(/^#{event_id}/)[0]
	if repo_filename && (repo_filename != filename) then
		# filename has changed, remove old file
		g.remove repo_filename
	end
	open "#{g.dir.path}/#{filename}", 'w' do |f|
		f.print content
	end
	g.add filename
end

begin
	g.commit 'Updated from upstream'
rescue Git::GitExecuteError
	puts "no changes"
end

#!/usr/bin/env ruby

require 'rubygems'
require 'mechanize'
require 'yaml'
require 'pp'
require 'erb'
require 'rt/client'
require 'uri'
require 'digest/md5'

# work around a problem in rt/client, rt.correspond does not work there,
# so do it manually via mechanize
def correspond_ticket(rt, id, text)
	cookie_key, cookie_value = rt.cookie.split("=")
	cookie = Mechanize::Cookie.new(cookie_key, cookie_value)
	cookie.domain = RT_COOKIE_DOMAIN
	cookie.path   = RT_COOKIE_PATH

	mechrt = Mechanize.new
	mechrt.cookie_jar.add(URI.parse(RT_SERVER), cookie)
	page = mechrt.get("https://rt.cccv.de/Ticket/Update.html?Action=Respond&id=#{id}")
	f = page.form_with(:name => 'TicketUpdate')

	f.textareas[0].value = text
	# set status to 'stalled' so ticket does not show up on list of open tickets
	# gets changed to open once requestor replies
	f.fields_with(:name => 'Status').first.value = 'stalled'
	f.click_button f.button_with(:name => 'SubmitTicket')
end

ACCEPTANCE_SUBJECT = 'Acceptance'
REJECTION_SUBJECT  = 'Rejection'
DEFAULT_EVENT_IMAGE_MD5 = '8edbc805920bcaf3d788db4e1d33b254'

COORDINATORS = {
	# ID => [ 'RT username', 'signature']
	'2014' => [ 'alech', 'Alex' ]
}
RT_SERVER = 'https://rt.cccv.de'
RT_COOKIE_DOMAIN = 'rt.cccv.de'
RT_COOKIE_PATH   = '/'
RT_QUEUE  = '28c3-content'
@proceedings = true

STDIN.sync = true

config = open(File.join(File.expand_path('~'), '.offlinebarf.cfg')) do |f|
	YAML.load(f)
end

mech = Mechanize.new
mech.basic_auth(config['username'], config['password'])

rt = RT_Client.new(
	:server   => RT_SERVER,
	:user     => config['rt-username'],
	:pass     => config['rt-password']
)

# get all event IDs
#events_page = mech.get('https://cccv.pentabarf.org/csv/events').body
#events = events_page.split("\n").map do |event|
#	event.split(',')[0]
#end[1..-1].sort { |a,b| b.to_i <=> a.to_i }

# testing
events = [ '4868' ]

events.each do |event_id|
	event    = mech.get("https://cccv.pentabarf.org/event/edit/#{event_id}")
	@title    = event.search('//input[@id="event[title]"]').attr('value').to_s
	state    = event.search('//select[@id="event[event_state]"]' \
	                        '/option[@selected]').attr('value').to_s
	progress = event.search('//select[@id="event[event_state_progress]"]' \
	                        '/option[@selected]').attr('value').to_s
	lang     = event.search('//select[@id="event[language]"]' \
	                        '/option[@selected]').attr('value').to_s
	@paper   = event.search('//select[@id="event[paper]"]' \
	                        '/option[@selected]').attr('value').to_s == 'true'
	if lang != 'de' && lang != 'en' then
		lang = 'en' # default to english if language is not set
	end
	type     = event.search('//select[@id="event[event_type]"]' \
	                        '/option[@selected]').attr('value')
	# ignore workshops, already confirmed/reconfirmed events and undecided ones
	puts "#{event_id} - #{state} - #{@title} - #{progress} - #{lang} - #{type}"
	next if type == 'workshop'
	next if progress == 'confirmed' || progress == 'reconfirmed'
	next if state != 'accepted' && state != 'rejected'
	puts "Sending out notification"


	# get event persons
	js = event.search('//script[@type="text/javascript"]')
	add_ev_person_js = js.select { |j| j.inner_html[/add_event_person/] }[0]
	rows = add_ev_person_js.inner_html.split("\n").select { |r| r[/^add_event_person/] }
	statements = rows[0].split(';').select { |s| s[/add_event_person/] }
	persons = statements.map do |r|
		r[/add_event_person\((.*)\)/, 1].split(',').map! do |e|
			e.gsub("'", '')
		end[2..4]
	end
	coordinator = persons.select { |p| p[1] == 'coordinator' }.map { |p| p[0] }.first
	if ! coordinator || ! COORDINATORS[coordinator] then
		STDERR.puts "No (known) coordinator, skipping #{event_id}"
		next
	end
	@coordinator_sig = COORDINATORS[coordinator][1]

	persons = persons.select { |p| p[1] == 'speaker' }.map { |p| p[0] }

	# get logo to see if it is custom
	@custom_logo = false
	logo = mech.get("https://cccv.pentabarf.org/image/event/#{event_id}.128x128").body
	if Digest::MD5.hexdigest(logo) != DEFAULT_EVENT_IMAGE_MD5 then
		@custom_logo = true
	end

	# get mail addresses and user detailsfrom user pages
	@recipients = []
	@availability_filled_out   = true
	@person_details_filled_out = true
	persons.each do |p|
		user_page = mech.get("https://cccv.pentabarf.org/person/edit/#{p}")
		availability_checkboxes = user_page.forms[1].checkboxes.select { |c| c.name[/person_availability/] }
		availability_amount     = availability_checkboxes.select { |c| c.checked }.size
		non_availability_amount = availability_checkboxes.select { |c| ! c.checked }.size
		if availability_amount == 0 || non_availability_amount == 0 then
			# if availability is all checked or all not, this does not look
			# like conscious thought
			@availability_filled_out = false
		end
		person_abstract_size = user_page.search('//textarea[@id="conference_person[abstract]"]').first.inner_html.size
		person_description_size = user_page.search('//textarea[@id="conference_person[description]"]').first.inner_html.size
		if (person_abstract_size + person_description_size) == 0 then
			@person_details_filled_out = false
		end
		@recipients << [
			user_page.search('//input[@id="person[public_name]"]').first.attr('value'),
			user_page.search('//input[@id="person[email]"]').first.attr('value'),
		]
	end
	
	template_filename = "template_#{state}_#{lang}.txt"
	if ! File.exist? template_filename then
		STDERR.puts "No template file #{template_filename} found!"
		exit 1
	end
	template = File.read(template_filename)
	message  = ERB.new(template, 0, "%<>")
	content  = message.result

	subject = "28C3-#{event_id}: #{@title}"

	rt_id = rt.create(
		:Queue      => RT_QUEUE,
		:Subject    => subject,
		:Owner      => COORDINATORS[coordinator][0],
		:Requestors => @recipients.map { |r| r[1] }.join(', '),
		:Text       => "#{state}. automatic notification via notification.rb"
		# TODO Pentabarf-URL custom field
	)
	correspond_ticket(rt, rt_id, content)

	next_state = (state == 'accepted') ? 'confirmed' : 'reconfirmed'
	event.forms[2].field_with(:id => 'event[event_state_progress]').value = next_state
	event.forms[2].submit

	# TODO: add link in Pentabarf to ticket
end

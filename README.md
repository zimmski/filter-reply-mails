# filter-reply-mails

This perl script was created out of the need to filter and modify mails from an IMAP folder and forward them to the JIRA issue tracker for creating new issues and comments. As JIRA does not support a sane way to deal with HTML mails (especially mails from Outlook) and to remove unnecessary signatures and their including attachments. I am sure that there are other use cases for this script too, so please let me know!

## What does it do?

This perl script connects to an IMAP server and fetches (and by default deletes) all mails from a specific IMAP folder to a temporary FS folder. All mails are trimmed by a set of regexes defined in two different files. One file holds regexes for TEXT parts of the mails while the other file holds regexes for HTML parts. Each line in these files defines one regex. HTML parts can reference images therefore all referenced images of trimmed content are removed from the mail. After a mail has been trimmed it is moved to the destination FS folder.

I tried to use self-explanatory options and arguments for the script. Please execute the script with the --help argument or have a look at the example below.

## JIRA example use case

1. Go to the "Incoming Mail" section in the administration and add a mail handler with the server "Local Files" and the handler "Add a comment from the non quoted email body". Test and save the handler. This handler looks for mails in the folder /import/mail of your JIRA user home folder.
2. Put the script and the two regex files somewhere where the JIRA user can execute the script.
3. Create a folder where temporary data can be stored by the script.
4. Create a cronjob for the JIRA user wtih the following command.

	``` bash
	perl /path/to/the/filter-reply-mails.pl --mail-server your.mail.server.domain --mail-user your-mail-user --mail-pwd your-mail-password --folder-tmp /the/tmp/folder --folder-dst /your/jira/home/folder/import/mail --filter-html /path/to/the/filter-html.regex --filter-text /path/to/the/filter-text.regex
	```

That's it! If you need a SSL or TLS IMAP connection just use the corresponding --mail-ssl or --mail-tls flag for the command. If you need to use a different port for the IMAP connection you can define it via the --mail-server argument e.g. "--mail-server 'your.mail.server.domain:143'".

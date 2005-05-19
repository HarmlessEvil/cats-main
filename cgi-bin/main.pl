#!/usr/bin/perl -w
use strict;
use File::Temp;
use File::Temp qw/tempfile/;
use Encode;
use encoding 'utf8';
#use CGI::Fast qw(:standard);
use CGI qw(:standard);
use CGI::Util qw(rearrange unescape escape);
#use FCGI;

use Algorithm::Diff;

use cats;
use cats_misc qw(:all);
use cats_ip;
use problem;

use vars qw( $html_code $current_pid );


sub login_frame {
    
    init_template( "main_login.htm" );

    my $login = param('login') or return;   
    $t->param(login => $login); 
    my $cid = param('contest');
    my $passwd = param('passwd');

    my ($aid, $passwd3, $locked) = $dbh->selectrow_array(
        qq~SELECT id, passwd, locked FROM accounts WHERE login=?~, {}, $login);

    $aid or return msg(39);

    $passwd3 eq $passwd or return msg(40);

    !$locked or msg(41);

    my $ok = 0;
    my @ch = ('A'..'Z', 'a'..'z', '0'..'9');
    foreach (1..20)
    {
        $sid = join '', map { $ch[rand @ch] } 1..30;
        
        my $last_ip = cats_ip::get_ip();
        
        if ($dbh->do(
            qq~UPDATE accounts SET sid=?, last_login=CATS_SYSDATE(), last_ip=? WHERE id=?~,
            {}, $sid, $last_ip, $aid
        ))
        { 
            $dbh->commit;

            my $cid = $dbh->selectrow_array(qq~SELECT id FROM contests WHERE ctype=1~);

            $t = undef;
            print redirect(-uri => url_function('contests', sid => $sid, cid => $cid));
            return;              
        }
    }
    die 'Can not generate sid';
}


sub logout_frame {

    init_template('main_logout.htm');

    $cid = '';
    $sid = '';
    $t->param(href_login => url_f('login'));

    $dbh->do(qq~UPDATE accounts SET sid = NULL WHERE id = ?~, {}, $uid);
    $dbh->commit;

    $sid = '';
}


sub contests_new_frame
{
    init_template('main_contests_new.htm');

    my $date = $dbh->selectrow_array(qq~SELECT CATS_DATE(CATS_SYSDATE()) FROM accounts~);
    $date =~ s/\s*$//;
    $t->param ( start_date => $date, freeze_date => $date, finish_date => $date, open_date => $date,
                href_action => url_f('contests') );
}


sub contest_checkbox_params()
{qw(
    free_registration run_all_tests
    show_all_tests show_test_resources show_checker_comment
    is_official show_packages
)}


sub contest_string_params()
{qw(
    contest_name start_date freeze_date finish_date open_date
)}


sub get_contest_html_params
{
    my $p = {};
    
    $p->{$_} = param($_) for contest_string_params();
    $p->{$_} = param($_) eq 'on' for contest_checkbox_params();
    
    if ($p->{contest_name} eq '' || length $p->{contest_name} > 100)
    {
        msg(27);
        return;
    }
    
    $p;
}


sub contests_new_save
{
    my $p = get_contest_html_params() or return;

    my $cid = new_id;
    # free_registration => closed
    $p->{free_registration} = !$p->{free_registration};
    $dbh->do(qq~
        INSERT INTO contests (
          id, title, start_date, freeze_date, finish_date, defreeze_date,
          ctype,
          closed, run_all_tests, show_all_tests,
          show_test_resources, show_checker_comment, is_official, show_packages
        ) VALUES(
          ?, ?, CATS_TO_DATE(?), CATS_TO_DATE(?), CATS_TO_DATE(?), CATS_TO_DATE(?),
          0,
          ?, ?, ?, ?, ?, ?, ?)~,
        {},
        $cid, @$p{contest_string_params()},
        @$p{contest_checkbox_params()}
    );

    # ������������� ���������������� ���� ��������������� ��� ����
    my $root_accounts = $dbh->selectcol_arrayref(qq~
        SELECT id FROM accounts WHERE srole = ?~, undef, $cats::srole_root);
    for (@$root_accounts)
    {
        $dbh->do(qq~
            INSERT INTO contest_accounts (
              id, contest_id, account_id,
              is_jury, is_pop, is_hidden, is_ooc, is_remote
            ) VALUES (?,?,?,?,?,?,?,?)~,
            {},
            new_id, $cid, $_,
            1, 1, 1, 1, 1
        );
    }
    $dbh->commit;
}


sub contests_edit_frame
{
    init_template('main_contests_edit.htm');  

    my $id = url_param('edit');

    my $p = $dbh->selectrow_hashref(qq~
        SELECT
          title AS contest_name,
          CATS_DATE(start_date) AS start_date,
          CATS_DATE(freeze_date) AS freeze_date,
          CATS_DATE(finish_date) AS finish_date,
          CATS_DATE(defreeze_date) AS open_date,
          1 - closed AS free_registration,
          run_all_tests, show_all_tests, show_test_resources, show_checker_comment,
          is_official, show_packages
        FROM contests WHERE id=?~, { Slice => {} },
        $id
    );
    # Ask: ��������, �� ����� ���� ���� ��������� CATS_DATE
    for (qw(start_date freeze_date finish_date open_date)) {
        $p->{$_} =~ s/\s*$//;
    }
    $t->param(id => $id, %$p, href_action => url_f('contests'));
}


sub contests_edit_save
{    
    my $edit_cid = param('id');
    
    my $p = get_contest_html_params() or return;
    
    # free_registration => closed
    $p->{free_registration} = !$p->{free_registration};
    $dbh->do(qq~
        UPDATE contests SET
          title=?, start_date=CATS_TO_DATE(?), freeze_date=CATS_TO_DATE(?), 
          finish_date=CATS_TO_DATE(?), defreeze_date=CATS_TO_DATE(?),
          closed=?, run_all_tests=?, show_all_tests=?,
          show_test_resources=?, show_checker_comment=?, is_official=?, show_packages=?
          WHERE id=?~,
        {},
        @$p{contest_string_params()},
        @$p{contest_checkbox_params()},
        $edit_cid
    );
    $dbh->commit;
    # ���� ������������� ������ ������, ����� �������� ��������� ����
    if ($edit_cid == $cid) {
        $contest_title = $p->{contest_name};
    }
}


sub get_registered_contestant
{
    my %p = @_;
    $p{fields} ||= 1;
    $p{account_id} ||= $uid;
    $dbh->selectrow_array(qq~
        SELECT $p{fields} FROM contest_accounts WHERE contest_id=? AND account_id=?~,
        {}, $p{contest_id}, $p{account_id});
}


sub contest_online_registration
{
    !get_registered_contestant(contest_id => $cid)
        or return msg(111);

    my ($finished, $closed) = $dbh->selectrow_array(qq~
        SELECT CATS_SYSDATE() - finish_date, closed FROM contests WHERE id=?~, {}, $cid);
        
    $finished <= 0
        or return msg(108);

    !$closed
        or return msg(105);

    $dbh->do(qq~
        INSERT INTO contest_accounts (id, contest_id,
          account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote, is_virtual, diff_time)
        VALUES (?,?,?,?,?,?,?,?,?,?)~, {},
          new_id, $cid, $uid, 0, 0, 0, 1, 1, 0, 0);
    $dbh->commit;
}


sub contest_virtual_registration
{
    my ($registered, $is_virtual) = get_registered_contestant(
         fields => '1, is_virtual', contest_id => $cid);
        
    !$registered || $is_virtual
        or return msg(114);

    my ($time_since_start, $time_since_finish, $closed, $is_official) = $dbh->selectrow_array(qq~
        SELECT CATS_SYSDATE() - start_date, CATS_SYSDATE() - finish_date, closed, is_official
          FROM contests WHERE id=?~,
        {}, $cid);
        
    $time_since_start >= 0
        or return msg(109);
    
    $time_since_finish >= 0 || !$is_official
        or return msg(122);

    !$closed
        or return msg(105);

    # ��� ��������� ����������� ������� ������ ����������
    if ($registered)
    {
        $dbh->do(qq~DELETE FROM reqs WHERE account_id=? AND contest_id=?~, {}, $uid, $cid);
        $dbh->do(qq~DELETE FROM contest_accounts WHERE account_id=? AND contest_id=?~, {}, $uid, $cid);
        $dbh->commit;
        msg(113);
    }

    $dbh->do(qq~
        INSERT INTO contest_accounts (
          id, contest_id, account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote, is_virtual, diff_time
        ) VALUES (
          ?,?,?,?,?,?,?,?,?,?
        )~, {}, 
        new_id, $cid, $uid, 0, 0, 0, 1, 1, 1, $time_since_start
    );
    $dbh->commit;
}


sub contests_select_current
{
    defined $uid or return;

    my ($registered, $is_virtual, $is_jury) = get_registered_contestant(
      fields => '1, is_virtual, is_jury', contest_id => $cid
    );
    return if $is_jury;
    
    my ($title, $time_since_finish) = $dbh->selectrow_array(qq~
        SELECT title, CATS_SYSDATE() - finish_date FROM contests WHERE id=?~, {}, $cid);

    $t->param(selected_contest_title => $title);

    if ($time_since_finish > 0) {
        msg(115);
    }
    elsif (!$registered) {
        msg(116);
    }   
}


sub contests_frame 
{    
    if (defined url_param('delete') && $is_root)   
    {    
        my $cid = url_param('delete');
        $dbh->do(qq~DELETE FROM contests WHERE id=?~, {}, $cid);
        $dbh->commit;       
    }

    if (defined url_param('new') && $is_root)
    {
        contests_new_frame;
        return;
    }

    if (defined url_param('edit') &&
        get_registered_contestant fields => 'is_jury', contest_id => param('edit'))
    {
        contests_edit_frame;
        return;
    }
    
    init_listview_template( 'contests_' . ($uid || ''), 'contests', "main_contests.htm" );

    if (defined param('new_save') && $is_root)
    {
        contests_new_save;
    }

    if (defined param('edit_save') &&
        get_registered_contestant fields => 'is_jury', contest_id => param('id'))
    {
        contests_edit_save;
    }

    if (defined param('online_registration'))
    {
        contest_online_registration;
    }

    my $vr = param('virtual_registration');
    if (defined $vr && $vr)
    {
        contest_virtual_registration;
    }
    
    if (defined url_param('set_contest'))
    {
        contests_select_current;
    }

    define_columns(url_f('contests'), 1, 1, [
        { caption => res_str(601), order_by => 'ctype DESC, title',       width => '40%' },
        { caption => res_str(600), order_by => 'ctype DESC, start_date',  width => '20%' },
        { caption => res_str(631), order_by => 'ctype DESC, finish_date', width => '20%' },
        { caption => res_str(630), order_by => 'ctype DESC, closed',      width => '20%' } ]);

    if (defined $uid)
    {
        my $c = $dbh->prepare(qq~
            SELECT id, title, CATS_DATE(start_date) AS start_date, CATS_DATE(finish_date) AS finish_date, 
              (SELECT COUNT(*) FROM contest_accounts WHERE contest_id=contests.id AND account_id=?) AS registered,
              (SELECT is_virtual FROM contest_accounts WHERE contest_id=contests.id AND account_id=?) AS is_virtual,
              (SELECT is_jury FROM contest_accounts WHERE contest_id=contests.id AND account_id=?) AS is_jury,
              CATS_SYSDATE() - start_date, closed, is_official
            FROM contests ~.order_by);
        $c->execute($uid, $uid, $uid);

        my $fetch_contest = sub($) 
        {
            my ( $contest_id, $contest_name, $start_date,
                $finish_date, $registered, $is_virtual,
                $is_jury, $start_diff_time,
                $registration_denied, $is_official
            ) = $_[0]->fetchrow_array
                or return ();

            my $started = $start_diff_time > 0;
            return (
                id => $contest_id,
                authorized => defined $uid,
                contest_name => $contest_name, 
                start_date => $start_date, 
                finish_date => $finish_date,
                editable => $is_jury,
                deletable => $is_root,
                registered_online => $registered && !$is_virtual,
                registered_virtual => $registered && $is_virtual, 
                registration_denied => $registration_denied,
                is_official => $is_official,
                href_contest => url_function('contests', sid => $sid, set_contest => 1, cid => $contest_id),
                selected => $contest_id == $cid,
                href_delete => url_f('contests', delete => $contest_id),
                href_edit => url_f('contests', edit => $contest_id) 
            );
        };

        attach_listview(url_f('contests'), $fetch_contest, $c);
    }
    else
    {
        my $c = $dbh->prepare(qq~
            SELECT id, title, CATS_DATE(start_date) AS start_date, CATS_DATE(finish_date) AS finish_date,
              closed, CATS_SYSDATE() - start_date, is_official FROM contests ~.order_by
        );
        $c->execute;

        my $fetch_contest = sub($)
        {
            my (
                $contest_id, $contest_name, $start_date, $finish_date, $registration_denied, $start_diff_time, $is_official
            ) = $_[0]->fetchrow_array
                or return ();
            my $started = $start_diff_time > 0;
            return (
                id => $contest_id,
                contest_name => $contest_name,
                start_date => $start_date,
                finish_date => $finish_date,
                registration_denied => $registration_denied,
                is_official => $is_official,
                selected => $contest_id == $cid,
                changeable => $started || $is_jury,
                href_contest =>
                    url_function('contests', sid => $sid, set_contest => 1, cid => $contest_id)
            );
        };

        attach_listview(url_f('contests'), $fetch_contest, $c);    
    }

    if ($is_root)
    {
        my @submenu = ( { href_item => url_f('contests', new => 1), item_name => res_str(537) } );
        $t->param(submenu => [ @submenu ] );
    }

    $t->param(authorized => defined $uid, href_contests => url_f('contests'));    
    $is_root && $t->param(editable => 1);
}

sub init_console_listview_additionals
{
    $additional ||= '1_hours';
    my $v = param('history_interval_value');
    my $u = param('history_interval_units');
    if (!defined $v || !defined $u)
    {
        ($v, $u) = ( $additional =~ /^(\d+)_(\w+)$/ );
        $v = 1 if !defined $v;
        $u = 'hours' if !defined $u; 
    }
    $additional = "${v}_$u";
    return ($v, $u);
}

sub russian ($)
{
    Encode::decode('KOI8-R', $_[0]);
}

sub console_read_time_interval
{
    my ($v, $u) = init_console_listview_additionals;
    my @text = split /\|/, res_str(121);
    my $units = [
        { value => 'hours', k => 0.04167 },
        { value => 'days', k => 1 },
        { value => 'months', k => 30 },
    ];
    map { $units->[$_]->{text} = $text[$_] } 0..$#$units;
    
    my $selected_unit = $units->[0];
    for (@$units)
    {
        if ($_->{value} eq $u)
        {
            $selected_unit = $_;
            last;
        }
    }
    $selected_unit->{selected} = 1;

    $t->param(
        'history_interval_value' => [
            map { {value => $_, text => $_ || russian('���'), selected => $v eq $_} } (1..5, 10, 0)
        ],
        'history_interval_units' => $units
    );

    return $v > 0 ? $v * $selected_unit->{k} : 100000;
}

sub console
{
    my $template_name = shift;
    init_listview_template("console$cid" . ($uid || ''), 'console', 'main_console_content.htm');

    my $day_count = console_read_time_interval;
    my %console_select = (
        run => q~
            1 AS rtype,
            R.submit_time AS rank,  
            CATS_DATE(R.submit_time) AS submit_time, 
            R.id AS id,
            R.state AS request_state,
            R.failed_test AS failed_test,
            P.title AS problem_title,
            CAST(NULL AS INTEGER) AS clarified,
            D.t_blob AS question,
            D.t_blob AS answer,
            D.t_blob AS jury_message,
            A.team_name AS team_name,
            A.country AS country,
            A.last_ip AS last_ip,
            CA.id~,
        question => q~
            2 AS rtype,
            Q.submit_time AS rank,
            CATS_DATE(Q.submit_time) AS submit_time,  
            Q.id AS id,
            CAST(NULL AS INTEGER) AS request_state,
            CAST(NULL AS INTEGER) AS failed_test,
            CAST(NULL AS VARCHAR(200)) AS problem_title,
            Q.clarified AS clarified,
            Q.question AS question,
            Q.answer AS answer,
            D.t_blob AS jury_message,
            A.team_name AS team_name,
            A.country AS country,
            A.last_ip AS last_ip,
            CA.id~,
        message => q~
            3 AS rtype,
            M.send_time AS rank,
            CATS_DATE(M.send_time) AS submit_time,  
            M.id AS id,
            CAST(NULL AS INTEGER) AS request_state,
            CAST(NULL AS INTEGER) AS failed_test,
            CAST(NULL AS VARCHAR(200)) AS problem_title,
            CAST(NULL AS INTEGER) AS clarified,
            D.t_blob AS question,
            D.t_blob AS answer,
            M.text AS jury_message,
            A.team_name AS team_name,
            A.country AS country,
            A.last_ip AS last_ip,
            CA.id
        ~,
        broadcast => q~
            4 AS rtype,
            M.send_time AS rank,
            CATS_DATE(M.send_time) AS submit_time,  
            M.id AS id,
            CAST(NULL AS INTEGER) AS request_state,
            CAST(NULL AS INTEGER) AS failed_test,
            CAST(NULL AS VARCHAR(200)) AS problem_title,
            CAST(NULL AS INTEGER) AS clarified,
            D.t_blob AS question,
            D.t_blob AS answer,
            M.text AS jury_message,
            CAST(NULL AS VARCHAR(200)) AS team_name,
            CAST(NULL AS VARCHAR(30)) AS country,
            CAST(NULL AS VARCHAR(100)) AS last_ip,
            CAST(NULL AS INTEGER)
        ~,
    );

    my $my_events_only = url_param('my') || '';
    if ($my_events_only !~ /[01]/)
    {
        $my_events_only = !$is_jury;
    }
    my $events_filter = $my_events_only ? 'AND A.id = ?' : '';
    my @events_filter_params = $my_events_only ? ($uid) : ();
    
    my $c;
    if ($is_jury)
    {
        $c = $dbh->prepare(qq~
            SELECT
                $console_select{run}
                FROM reqs R, problems P, accounts A, contest_accounts CA, dummy_table D 
                WHERE (R.submit_time > CATS_SYSDATE() - $day_count) AND
                R.problem_id=P.id AND R.account_id=A.id AND CA.account_id=A.id AND CA.contest_id=R.contest_id
                $events_filter
            UNION
            SELECT
                $console_select{question}
                FROM questions Q, contest_accounts CA, dummy_table D, accounts A
                WHERE (Q.submit_time > CATS_SYSDATE() - $day_count) AND
                Q.account_id=CA.id AND A.id=CA.account_id
                $events_filter
            UNION
            SELECT
                $console_select{message}
                FROM messages M, contest_accounts CA, dummy_table D, accounts A
                WHERE (M.send_time > CATS_SYSDATE() - $day_count) AND
                M.account_id=CA.id AND A.id=CA.account_id
                $events_filter
	        UNION
            SELECT
                $console_select{broadcast}
                FROM messages M, dummy_table D
                WHERE (M.send_time > CATS_SYSDATE() - $day_count) AND M.broadcast=1
            ORDER BY 2 DESC~);
        $c->execute(@events_filter_params, @events_filter_params, @events_filter_params);
    }
    elsif ($is_team)
    {
        $c = $dbh->prepare(
           qq~SELECT
                $console_select{run}
                FROM reqs R, problems P, accounts A, contests C, dummy_table D, contest_accounts CA
                WHERE (R.submit_time > CATS_SYSDATE() - $day_count) AND
                R.problem_id=P.id AND R.contest_id=C.id AND C.id=? AND R.account_id=A.id AND
                CA.account_id=A.id AND CA.contest_id=C.id AND CA.is_hidden=0 AND
                (A.id=? OR (R.submit_time < C.freeze_date OR CATS_SYSDATE() > C.defreeze_date))
                $events_filter
            UNION
            SELECT
                $console_select{question}
                FROM questions Q, contest_accounts CA, dummy_table D, accounts A
                WHERE (Q.submit_time > CATS_SYSDATE() - $day_count) AND
                Q.account_id=CA.id AND CA.contest_id=? AND CA.account_id=A.id AND A.id=?
                $events_filter
            UNION
            SELECT
                $console_select{message}
                FROM messages M, contest_accounts CA, dummy_table D, accounts A 
                WHERE (M.send_time > CATS_SYSDATE() - $day_count) AND
                M.account_id=CA.id AND CA.contest_id=? AND CA.account_id=A.id AND A.id=?
                $events_filter
	        UNION
            SELECT
                $console_select{broadcast}
                FROM messages M, dummy_table D
                WHERE (M.send_time > CATS_SYSDATE() - $day_count) AND M.broadcast=1
            ORDER BY 2 DESC~);
        $c->execute(
            $cid, $uid, @events_filter_params,
            $cid, $uid, @events_filter_params,
            $cid, $uid, @events_filter_params
        );
    }
    else
    {
        $c = $dbh->prepare(qq~
            SELECT
                $console_select{run}
                FROM reqs R, problems P, accounts A, dummy_table D, contests C, contest_accounts CA
                WHERE (R.submit_time > CATS_SYSDATE() - $day_count) AND
                R.problem_id=P.id AND R.contest_id=? AND R.account_id=A.id AND C.id=R.contest_id AND
                CA.account_id=A.id AND CA.contest_id=C.id AND CA.is_hidden=0 AND 
                (R.submit_time < C.freeze_date OR CATS_SYSDATE() > C.defreeze_date)
                $events_filter
            UNION
            SELECT
                $console_select{broadcast}
                FROM messages M, dummy_table D
                WHERE (M.send_time > CATS_SYSDATE() - $day_count) AND M.broadcast=1
            ORDER BY 2 DESC~);
        $c->execute($cid, @events_filter_params);
    }
    
    my $fetch_console_record = sub($)
    {            
        my ($rtype, $rank, $submit_time, $id, $request_state, $failed_test, 
            $problem_title, $clarified, $question, $answer, $jury_message,
            $team_name, $country_abb, $last_ip, $caid
        ) = $_[0]->fetchrow_array
            or return ();

        $request_state = -1 unless defined $request_state;
  
        my ($country, $flag) = get_flag($country_abb);
        $last_ip = cats_ip::filter_ip($last_ip);
        return (
            country => $country,
            flag => $flag, 
            is_submit_result =>     $rtype == 1,
            is_question =>          $rtype == 2,
            is_message =>           $rtype == 3,
            is_broadcast =>         $rtype == 4,
            clarified =>            $clarified,
            href_details =>         url_f(($is_jury ? 'submit_details' : 'run_details'), rid => $id),
            href_answer_box =>      $is_jury ? url_f('answer_box', qid => $id) : undef,
            href_send_message_box =>$is_jury ? url_f('send_message_box', caid => $caid) : undef,
            time =>                 $submit_time,
            problem_title =>        $problem_title,
            state_to_display($request_state),
            failed_test_index =>    $failed_test,
            question_text =>        $question,
            answer_text =>          $answer,
            message_text =>         $jury_message,
            team_name =>            $team_name,
            last_ip =>              $last_ip,
            is_jury =>              $is_jury
        );
    };
            
    attach_listview(url_f('console'), $fetch_console_record, $c);
      
    $c->finish;

    if ($is_team)
    {
        my @envelopes;
        my $c = $dbh->prepare(qq~
            SELECT id FROM reqs
              WHERE account_id=? AND state>=$cats::request_processed AND received=0 AND contest_id=?~
        );
        $c->execute($uid, $cid);
        while (my ($id) = $c->fetchrow_array)
        {
            push @envelopes, { href_envelope => url_f('envelope', rid => $id) };
        }
        
        $t->param(envelopes => [ @envelopes ]);

        $dbh->do(qq~UPDATE reqs SET received=1 
                    WHERE account_id=? AND state>=$cats::request_processed 
                    AND received=0 AND contest_id=?~, {}, $uid, $cid);
        $dbh->commit;
    }

    $t->param(
        my_events_only => $my_events_only,
        href_my_events_only => url_f('console', my => 1),
        href_all_events => url_f('console', my => 0),
    );
    my $s = $t->output;
    init_template($template_name);

    $t->param(
        console_content => $s,
        is_team => $is_team,
    );
}


sub console_frame
{        
    init_listview_template( "console$cid" . ($uid || ''), 'console', 'main_console.htm' );  
    init_console_listview_additionals;
    
    my $my_events_only = url_param('my');
    $t->param(
        href_console_content => url_f('console_content', my => $my_events_only),
        is_team => $is_team
    );
    
    defined param('send_question') && $is_team or return;
    my $question_text = param('question_text');
    defined $question_text && $question_text ne '' or return;

    my $cuid = get_registered_contestant(fields => 'id', contest_id => $cid);

    my $q = $dbh->prepare(qq~SELECT question FROM questions WHERE account_id=? ORDER BY submit_time DESC~);
    $q->bind_param(1, $cuid);
    $q->execute;
    my ($previous_question_text) = $q->fetchrow_array;
    $previous_question_text ne $question_text or return;
    
    my $s = $dbh->prepare(qq~
        INSERT INTO questions(id, account_id, submit_time, question, received, clarified)
        VALUES (?, ?, CATS_SYSDATE(), ?, 0, 0)~
    );
    $s->bind_param(1, new_id);
    $s->bind_param(2, $cuid);       
    $s->bind_param(3, $question_text, { ora_type => 113 } );
    $s->execute;
    $s->finish;
    $dbh->commit;
}


sub console_content_frame
{
    console( "main_console_iframe.htm" );  
}


sub problems_new_frame
{
    init_template( "main_problems_new.htm" );

    my ( %cl, @code_array );
    my $c = $dbh->prepare(qq~SELECT code FROM contest_problems WHERE contest_id=?~);    

    $c->execute( $cid );

    while ( my $code = $c->fetchrow_array ) 
    { 
        $cl{ $code } = 1; 
    }
    $c->finish;

    my $too_many_problems = 1;
    foreach ( 'A'..'Z' ) { unless ( defined $cl{ $_ } ) { push( @code_array, { code => $_ } ), $too_many_problems = 0; } };

    $t->param(code_array => [ @code_array ]);
    $t->param(too_many_problems => $too_many_problems);
    $t->param(href_action => url_f('problems'));
}


sub problems_new_save
{
    my $file = param('zip');

    if ($file eq '') {
        msg(53);
        return;
    }

    my ( $fh, $fname ) = tmpnam;
    my ( $br, $buffer );
       
    while ( $br = read( $file, $buffer, 1024 ) ) {
    
        syswrite($fh, $buffer, $br);
    }

    close $fh;

    my $pid = new_id;
    my $problem_code = param('problem_code');
    
    my ($st, $import_log) = problem::import_problem($fname, $cid, $pid, 0);
   
    $import_log = Encode::encode_utf8( escape_html($import_log) );  
    $t->param(problem_import_log => $import_log);

    $st ||= !$dbh->do(qq~INSERT INTO contest_problems(id, contest_id, problem_id, code) VALUES (?,?,?,?)~, 
       {}, new_id, $cid, $pid, $problem_code);

    (!$st) ? $dbh->commit : $dbh->rollback;
    if ($st) { msg(52); }         
}


sub problems_link_frame
{
    init_listview_template( 'link_problem_' || ($uid || ''), "link_problem", "main_problems_link.htm" );

    my ( %cl, @code_array );
    {
    my $c = $dbh->prepare(qq~SELECT code FROM contest_problems WHERE contest_id=?~);    

    $c->execute( $cid );

    while ( my $code = $c->fetchrow_array ) 
    { 
        $cl{ $code } = 1; 
    }
    $c->finish;
    }
    
    my $too_many_problems = 1;
    foreach ( 'A'..'Z' ) { unless ( defined $cl{ $_ } ) { push( @code_array, { code => $_ } ), $too_many_problems = 0; } };

    $t->param(code_array => [ @code_array ]);
    $t->param(too_many_problems => $too_many_problems);

    my @cols = 
              ( { caption => res_str(602), order_by => '2', width => '30%' }, 
                { caption => res_str(603), order_by => '3', width => '30%' },                    
                { caption => res_str(604), order_by => '4', width => '10%' },
                { caption => res_str(605), order_by => '5', width => '10%' },
                { caption => res_str(606), order_by => '6', width => '10%' } );

    define_columns(url_f('problems', link => 1), 0, 0, [ @cols ]);
    {   
    my $c = $dbh->prepare(qq~
               SELECT P.id, P.title, C.title, 
                 (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_accepted), 
                 (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_wrong_answer), 
                 (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_time_limit_exceeded),
                 (SELECT COUNT(*) FROM contest_problems CP WHERE CP.problem_id = P.id AND CP.contest_id=?)
               FROM problems P, contests C
               WHERE C.id=P.contest_id 
               ~.order_by);
    $c->execute($cid);


    my $fetch_record = sub($)
    {            
        if ( my( $pid, $problem_name, $contest_name, $accept_count, $wa_count, $tle_count, $linked ) = $_[0]->fetchrow_array)
        {    
            return ( 
                linked => $linked,
                problem_id => $pid,
                problem_name => $problem_name, 
                href_view_problem => url_f('problem_text', pid => $pid),
                contest_name => $contest_name, 
                accept_count => $accept_count, 
                wa_count => $wa_count,
                tle_count => $tle_count
            );
        }   

        return ();
    };
            
    attach_listview(url_f('problems', link => 1), $fetch_record, $c);

    $t->param(practice => $is_practice, href_action => url_f('problems'));
    
    $c->finish;
    }
}


sub problems_link_save
{       
    my $pid = param('problem_id');
    my $problem_code = undef;
    if (!$is_practice)
    {
        $problem_code = param('problem_code');
    }    
    
    if (!defined $pid)
    {
        msg(104);
        return;
    }

    $dbh->do(qq~INSERT INTO contest_problems(id, contest_id, problem_id, code) VALUES (?,?,?,?)~, 
       {}, new_id, $cid, $pid, $problem_code);

    $dbh->commit;
}


sub problems_replace_frame
{
    init_template( "main_problems_replace.htm" );

    my $cpid = url_param('replace');
     
    my ($pid, $problem_name) = $dbh->selectrow_array(
                    qq~SELECT P.id, CP.code||' - '||P.title FROM contest_problems CP, problems P 
                        WHERE P.id=CP.problem_id AND CP.id=?~, {}, $cpid);                          
    my ($contest_id) = $dbh->selectrow_array(qq~SELECT contest_id FROM problems WHERE id=?~, {}, $pid);

    $t->param(linked_problem => ($contest_id != $cid));
    $t->param(id => $pid, problem_name => $problem_name, href_action => url_f('problems'));
}


sub problems_replace_save
{
    my $file = param('zip');

    if ($file eq '') {
        msg(53);
        return;
    }

    my ( $fh, $fname ) = tmpnam;
    my ( $br, $buffer );            

    while ( $br = read( $file, $buffer, 1024 ) ) {
    
        syswrite($fh, $buffer, $br);
    }

    close $fh;

    my $pid = param('id');
   
    my ($st, $import_log) = problem::import_problem($fname, $cid, $pid, 1);

    $import_log = Encode::encode_utf8( escape_html($import_log) );  
    $t->param(problem_import_log => $import_log);

    (!$st) ? $dbh->commit : $dbh->rollback;
    if ($st) { msg(52); }         
}


sub problems_replace_direct
{
    my $file = param('zip');

    if ($file !~ /\.(zip|ZIP)$/) {
        msg(53);
        return;
    }

    my ( $fh, $fname ) = tmpnam;
    my ( $br, $buffer );            

    while ( $br = read( $file, $buffer, 1024 ) ) {
    
        syswrite($fh, $buffer, $br);
    }

    close $fh;

    my $pid = param('problem_id');
    if (!$pid) {
        msg(53);
        return;
    }
   
    my ($contest_id) = $dbh->selectrow_array(qq~SELECT contest_id FROM problems WHERE id=?~, {}, $pid);
    if ($contest_id != $cid) {
      #$t->param(linked_problem => 1);
      msg(117);
      return;
    }
    my ($st, $import_log) = problem::import_problem($fname, $cid, $pid, 1);
    $import_log = Encode::encode_utf8( escape_html($import_log) );  
    $t->param(problem_import_log => $import_log);

    (!$st) ? $dbh->commit : $dbh->rollback;
    if ($st) { msg(52); }
}

sub download_problem {
    
    $t = undef;

    my $download_dir = './download';

    my $pid = param('download');

    my ( $fh, $fname ) = tempfile( 
        'problem_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX', 
        DIR => $download_dir, SUFFIX => ".zip"  );

    my ( $zip ) = 
        $dbh->selectrow_array(qq~SELECT zip_archive FROM problems WHERE id=?~, {}, $pid);

    syswrite($fh, $zip, length($zip));    

    close $fh;
    
    print redirect(-uri=> "$fname");
}



sub get_source_de {

     my $file_name = shift;

     my $c = $dbh->prepare(qq~SELECT id, code, description, file_ext FROM default_de WHERE in_contests=1 ORDER BY code~);
     $c->execute;
    
     my ( $vol, $dir, $fname, $name, $ext ) = split_fname( lc $file_name );

     while ( my ( $did, $code, $description, $file_ext ) = $c->fetchrow_array )
     {
        my @ext_list = split( /\;/, $file_ext );
 
        foreach my $i ( @ext_list ) {
 
                if ( $i ne '' && $i eq $ext ) {
                    return ( $did, $description );
                }
        }
     }
     $c->finish;
    
     return undef;
}


sub problems_submit
{
    unless ($is_jury)
    {
        my ($time_since_start, $time_since_finish, $is_official) = $dbh->selectrow_array(qq~
            SELECT
              CATS_SYSDATE() - $virtual_diff_time - start_date,
              CATS_SYSDATE() - $virtual_diff_time - finish_date,
              is_official
            FROM contests WHERE id=?~,
            {}, $cid);
        
        $time_since_start >= 0
            or return msg(80);
        $time_since_finish <= 0  
            or return msg(81);
        
        unless ($is_official)
        {
            my ($current_official) = $dbh->selectrow_array(qq~
                SELECT title FROM contests
                  WHERE CATS_SYSDATE() BETWEEN start_date AND finish_date AND is_official = 1~);
            !$current_official
                or return msg(123, $current_official);
        }
    }
    
    my $file = param('source');
    $file ne '' or return msg(9);
    
    my $src = '';

    my ($br, $buffer);

    while ( $br = read($file, $buffer, 1024) )
    {
        length $src < 32767
            or return msg(10);
        $src .= $buffer;
    }
    
    $src ne '' or return msg(11);

    my $pid = param('problem_id')
        or return msg(12);

    my $did;

    defined param('de_id') or return msg(14);

    if ( param('de_id') eq 'by_extension' )
    {
        ($did, my $de_name) = get_source_de($file);
        
        defined $did or return msg(13);
        
        $t->param( de_name => $de_name );
    }
    else
    {
        $did = param('de_id');
    }

    my $rid = new_id;
    
    my $submit_uid = $uid;
    if (!defined $submit_uid && $is_practice)
    {
        $submit_uid = $dbh->selectrow_array(qq~
            SELECT id FROM accounts WHERE login=?~, {}, $cats::anonymous_login);
    }

    $dbh->do(qq~
        INSERT INTO reqs(
          id, account_id, problem_id, contest_id, 
          submit_time, test_time, result_time, state, received
        ) VALUES(
          ?,?,?,?,CATS_SYSDATE(),CATS_SYSDATE(),CATS_SYSDATE(),?,?)~,
        {}, $rid, $submit_uid, $pid, $cid, $cats::st_not_processed, 0);
    
    my $s = $dbh->prepare(qq~INSERT INTO sources(req_id, de_id, src, fname) VALUES (?,?,?,?)~ );
    $s->bind_param(1, $rid);
    $s->bind_param(2, $did);
    $s->bind_param(3, $src, { ora_type => 113 } ); # blob
    $s->bind_param(4, "$file");
    $s->execute;

    $dbh->commit;
    $t->param(solution_submitted => 1, href_console => url_f('console'));
    msg(15);
}



sub problems_submit_std_solution
{
    my $pid = param('problem_id');

    unless (defined $pid) {
        
        msg(12);
        return;
    }

    my $ok = 0;
    
    my $c = $dbh->prepare(qq~SELECT src, de_id, fname 
                            FROM problem_sources 
                            WHERE problem_id=? AND (stype=? OR stype=?)~);
    $c->execute($pid, $cats::solution, $cats::adv_solution);

    while (my ($src, $did, $fname) = $c->fetchrow_array)
    {
        my $rid = new_id;

        $dbh->do(qq~INSERT INTO reqs(id, account_id, problem_id, contest_id, 
            submit_time, test_time, result_time, state, received) VALUES(?,?,?,?,CATS_SYSDATE(),CATS_SYSDATE(),CATS_SYSDATE(),?,?)~,
            {}, $rid, $uid, $pid, $cid, $cats::st_not_processed, 0);
    
        my $s = $dbh->prepare(qq~INSERT INTO sources(req_id, de_id, src, fname) VALUES(?,?,?,?)~ );
        $s->bind_param(1, $rid);
        $s->bind_param(2, $did);
        $s->bind_param(3, $src, { ora_type => 113 } ); # blob
        $s->bind_param(4, $fname);             
        $s->execute;
        
        $ok = 1;
    }
    
    if ($ok)
    {
        $dbh->commit; 
        $t->param(solution_submitted => 1, href_console => url_f('console'));
        msg(107);
    }
    else {
        msg(106);
    }   
}


sub problems_frame 
{
    my $show_packages = 1;
    unless ($is_jury)
    {
        (my $start_diff_time, $show_packages) = $dbh->selectrow_array(qq~
            SELECT CATS_SYSDATE() - start_date, show_packages FROM contests WHERE id=?~,
            {}, $cid);
        if ($start_diff_time < 0) 
        {
            init_template( 'main_problems_inaccessible.htm' );      
            $t->param(problems_inaccessible => 1);
            return;
        }
    }


    if (defined url_param('new') && $is_jury)
    {
        problems_new_frame;
        return;
    }


    if (defined url_param('link') && $is_jury)
    {
        problems_link_frame;
        return;
    }


    if (defined url_param('replace') && $is_jury)
    {
        problems_replace_frame;
        return;
    }


    if (defined url_param('delete') && $is_jury)
    {
        my $cpid = url_param('delete');
        my $pid = $dbh->selectrow_array(qq~SELECT problem_id FROM contest_problems WHERE id=?~, {}, $cpid);

        $dbh->do(qq~DELETE FROM contest_problems WHERE id=?~, {}, $cpid);
        $dbh->commit;       

        unless ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM contest_problems WHERE problem_id=?~, {}, $pid))
        {
            $dbh->do(qq~DELETE FROM problems WHERE id=?~, {}, $pid);
            $dbh->commit;       
        }
    }
                                        

    if (defined param('download') && $show_packages)
    {
        download_problem;
        return;
    }


    init_listview_template( "problems$cid" . ($uid || ''), 'problems', 'main_problems.htm' );      

    if (defined param('link_save') && $is_jury)
    {
        problems_link_save;
    }

    if (defined param('new_save') && $is_jury)
    {
        problems_new_save;
    }


    if (defined param('replace_save') && $is_jury)
    {
        problems_replace_save;
    }

    if (defined param('replace_direct') && $is_jury)
    {
        problems_replace_direct;
    }


    if (defined param('submit'))
    {
        problems_submit;
    }

    if (defined param('std_solution'))
    {
        problems_submit_std_solution;
    }


    my @cols = (
        { caption => res_str(602), order_by => '3', width => '30%' },
        ($is_practice ?
        { caption => res_str(603), order_by => '4', width => '30%' } : ()
        ),
        { caption => res_str(604), order_by => '5', width => '5%' },
        { caption => res_str(605), order_by => '6', width => '5%' },
        { caption => res_str(606), order_by => '7', width => '5%' }
    );
    define_columns(url_f('problems'), 0, 0, [ @cols ]);

    my $c;
    if ($is_practice)
    {
        $c = $dbh->prepare(qq~
            SELECT CP.id, P.id, P.title, OC.title,
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_accepted),
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_wrong_answer),
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_time_limit_exceeded)
            FROM problems P, contests C, contest_problems CP, contests OC
            WHERE CP.contest_id=C.id AND CP.problem_id=P.id AND C.id=? AND OC.id=P.contest_id 
            ~.order_by);
        $c->execute($cid);
    }
    else
    {
        $c = $dbh->prepare(qq~
            SELECT CP.id, P.id, CP.code||' - '||P.title, NULL,
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_accepted AND D.account_id = ?),
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_wrong_answer AND D.account_id = ?),
              (SELECT COUNT(*) FROM reqs D WHERE D.problem_id = P.id AND D.state = $cats::st_time_limit_exceeded AND D.account_id = ?)
              FROM problems P, contest_problems CP
              WHERE CP.contest_id=? AND CP.problem_id=P.id
              ~.order_by);
        my $aid = $uid || 0; # �� ������ ���������� ������������
        # ����� ��� � �������� ����������
        $c->execute($cid, $aid, $aid, $aid);
    }

    my $fetch_record = sub($)
    {            
        if ( my( $cpid, $pid, $problem_name, $contest_name, $accept_count, $wa_count, $tle_count ) = $_[0]->fetchrow_array)
        {       
            return ( 
                href_delete   => url_f('problems', delete => $cpid ),
                href_replace  => url_f('problems', replace => $cpid),
                href_download => url_f('problems', download => $pid),
                show_packages => $show_packages,
                is_practice => $is_practice,
                editable => $is_jury,
                is_team => $is_team || $is_practice,
                problem_id => $pid,
                problem_name => $problem_name, 
                href_view_problem => url_f('problem_text', pid => $pid),
                contest_name => $contest_name,
                accept_count => $accept_count,
                wa_count => $wa_count,
                tle_count => $tle_count
            );
        }   

        return ();
    };
            
    attach_listview(url_f('problems'), $fetch_record, $c);

    $c->finish;

    $c = $dbh->prepare(qq~SELECT id, description FROM default_de WHERE in_contests=1 ORDER BY code~);
    $c->execute;

    my @de;
    push ( @de, { de_id => "by_extension", de_name => res_str(536) } );

    while ( my ( $de_id, $de_name ) = $c->fetchrow_array )
    {
        push ( @de, { de_id => $de_id, de_name => $de_name  } );
    }    

    $c->finish;
    
    my @submenu = ( { href_item => url_f('problem_text'), item_name => res_str(538), item_target=>'_blank' } );

    if ($is_jury)
    {
        push @submenu, (
            { href_item => url_f('problems', new => 1), item_name => res_str(539) },
            { href_item => url_f('problems', link => 1), item_name => res_str(540) } );
    };

    $t->param(submenu => [ @submenu ] );    
    $t->param(is_team => ($is_team || $is_practice), is_practice => $is_practice, de_list => [ @de ]);

    $is_jury && $t->param(editable => 1);
}



sub users_new_frame 
{
    init_template( "main_users_new.htm" );
    $t->param(login => generate_login);
    $t->param(countries => [ @cats::countries ], href_action => url_f('users'));    
}


sub users_new_save
{
    my $login = param('login');
    my $team_name = param('team_name');
    my $capitan_name = param('capitan_name');       
    my $email = param('email');     
    my $country = param('country'); 
    my $motto = param('motto');
    my $home_page = param('home_page');     
    my $icq_number = param('icq_number');
    my $password1 = param('password1');
    my $password2 = param('password2');

    unless ($login && length $login <= 100)
    {
        msg(101);
        return;
    }

    unless ($team_name && length $team_name <= 100)
    {
        msg(43);
        return;
    }

    if (length $capitan_name > 100)
    {
        msg(45);
        return;
    }

    if (length $motto > 200)
    {
        msg(44);
        return;
    }

    if (length $home_page > 100)
    {
        msg(48);
        return;
    }

    if (length $icq_number > 100)
    {
        msg(47);
        return;
    }

    if (length $password1 > 100)
    {
        msg(102);
        return;
    }          

    unless ($password1 eq $password2)
    {
        msg(33);
        return;
    }

    if ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM accounts WHERE login=?~, {}, $login))
    {
        msg(103);
        return;       
    }

    my $aid = new_id;
    my $caid = new_id;
        
    $dbh->do(qq~INSERT INTO accounts (id, login, passwd, srole, team_name, capitan_name, country, motto, email, home_page, icq_number) 
        VALUES(?,?,?,?,?,?,?,?,?,?,?)~, {}, $aid, $login, $password1, $cats::srole_user, $team_name, $capitan_name, $country, $motto, $email, $home_page, $icq_number) &&
    $dbh->do(qq~INSERT INTO contest_accounts (id, contest_id, account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote) 
        VALUES(?,?,?,?,?,?,?,?)~, {}, $caid, $cid, $aid, 0, 0, 0, 1, 0) ||
    do
    {
        $dbh->rollback;
    };
    
    my $c = $dbh->prepare(qq~SELECT id, closed FROM contests WHERE ctype=1~);
    $c->execute;
    while (my ($cid, $closed) = $c->fetchrow_array)
    {
        if ($closed)
        {
            msg(105);
            $dbh->rollback;
            return;
        }
        $dbh->do(qq~INSERT INTO contest_accounts (id, contest_id, account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote) 
            VALUES(?,?,?,?,?,?,?,?)~, {}, new_id, $cid, $aid, 0, 0, 0, 1, 0);
    }
              
    $dbh->commit;       
}


sub users_edit_frame 
{      
    my $id = url_param('edit');

    init_template('main_users_edit.htm');

    my ($login, $team, $capitan, $motto, $country, $email, $home_page, $icq_number) = $dbh->selectrow_array(qq~
        SELECT login, team_name, capitan_name, motto, country, email, home_page, icq_number
        FROM accounts WHERE id=?~, {}, $id);

    my $countries = [ @cats::countries ];

    foreach( @$countries ) 
    {
        $$_{selected} = $$_{id} eq $country;
    }

    $t->param(countries => $countries, login => $login, id => $id, href_action => url_f('users'),
            team => $team, capitan => $capitan, motto => $motto, country => $country, email => $email, 
            home_page => $home_page, icq_number => $icq_number, href_action => url_f('users'));
}


sub users_edit_save
{
    my $id = param('id');
    my $login = param('login');
    my $team_name = param('team_name');
    my $capitan_name = param('capitan_name');       
    my $email = param('email');     
    my $country = param('country'); 
    my $motto = param('motto');
    my $home_page = param('home_page');     
    my $icq_number = param('icq_number');
    my $set_password = param('set_password') eq 'on';
    my $password1 = param('password1');
    my $password2 = param('password2');

    unless ($login && length $login <= 100)
    {
        msg(101);
        return;
    }

    unless ($team_name && length $team_name <= 100)
    {
        msg(43);
        return;
    }

    if (length $capitan_name > 100)
    {
        msg(45);
        return;
    }

    if (length $motto > 200)
    {
        msg(44);
        return;
    }

    if (length $home_page > 100)
    {
        msg(48);
        return;
    }

    if (length $icq_number > 100)
    {
        msg(47);
        return;
    }

    if ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM accounts WHERE id<>? AND login=?~, {}, $id, $login))
    {
        msg(103);
        return;       
    }
 
    $dbh->do(qq~UPDATE accounts SET login=?, team_name=?, capitan_name=?, country=?, motto=?, email=?, home_page=?, icq_number=?
         WHERE id=?~, {}, $login, $team_name, $capitan_name, $country, $motto, $email, $home_page, $icq_number, $id);

    $dbh->commit;       


    if ($set_password)
    {        
        if (length $password1 > 100)
        {
            msg(102);
            return;
        }

        unless ($password1 eq $password2)
        {
            msg(33);
            return;
        }
        
        $dbh->do(qq~UPDATE accounts SET passwd=? WHERE id=?~, {}, $password1, $id);
        $dbh->commit; 
    }
}

sub users_send_message
{
    my %p = @_;
    $p{'message'} ne '' or return;
    my $s = $dbh->prepare(
        qq~INSERT INTO messages (id, send_time, text, account_id, received) VALUES(?, CATS_SYSDATE(), ?, ?, 0)~
    );
    foreach (split ':', $p{'user_set'})
    {
        next if param("msg$_") ne 'on';
        $s->bind_param(1, new_id);
        $s->bind_param(2, $p{'message'}, { ora_type => 113 });
        $s->bind_param(3, $_);
        $s->execute;
    }
    $s->finish;
}

sub users_send_broadcast
{
    my %p = @_;
    $p{'message'} ne '' or return;
    my $s = $dbh->prepare(
        qq~INSERT INTO messages (id, send_time, text, account_id, broadcast) VALUES(?, CATS_SYSDATE(), ?, NULL, 1)~
    );
    $s->bind_param(1, new_id);
    $s->bind_param(2, $p{'message'}, { ora_type => 113 });
    $s->execute;
    $s->finish;
}

sub users_register
{
    my ($login) = @_;
    defined $login && $login ne ''
        or return msg(118);

    my ($aid) = $dbh->selectrow_array(qq~SELECT id FROM accounts WHERE login=?~, {}, $login);
    $aid or return msg(118, $login);
    !get_registered_contestant(contest_id => $cid, account_id => $aid)
        or return msg(120, $login);

    $dbh->do(qq~
        INSERT INTO contest_accounts (
            id, contest_id, account_id, is_jury, is_pop,
            is_hidden, is_ooc, is_remote, is_virtual, diff_time
        ) VALUES (?,?,?,?,?,?,?,?,?,?)~, {}, 
        new_id, $cid, $aid, 0, 0, 0, 1, 1, 0, 0);
    $dbh->commit;
    msg(119, $login);
}

sub users_frame 
{    
    if (defined url_param('delete') && $is_jury)
    {
        my $caid = url_param('delete');
        my ($aid, $srole) = $dbh->selectrow_array(qq~SELECT A.id, A.srole FROM accounts A, contest_accounts CA WHERE A.id=CA.account_id AND CA.id=?~, {}, $caid);
            
        if ($srole)
        {
            $dbh->do(qq~DELETE FROM contest_accounts WHERE id=?~, {}, $caid);
            $dbh->commit;       

            unless ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM contest_accounts WHERE account_id=?~, {}, $aid))
            {
                $dbh->do(qq~DELETE FROM accounts WHERE id=?~, {}, $aid);
                $dbh->commit;       
            }
        }
    }

    if (defined url_param('new') && $is_jury)
    {        
        users_new_frame;
        return;
    };

    if (defined url_param('edit') && $is_jury)
    {        
        users_edit_frame;
        return;
    };


    init_listview_template( "users$cid" . ($uid || ''), 'users', 'main_users.htm' );      

    $t->param(messages => $is_jury);
    
    if (defined param('new_save') && $is_jury)       
    {
        users_new_save;
    };


    if (defined param('edit_save') && $is_jury)       
    {
        users_edit_save;
    };


    if (defined param('save_attributes') && $is_jury)
    {
        foreach (split(':', param('user_set')))
        {
            my $jury = param( "jury$_" ) eq 'on';
            my $ooc = param( "ooc$_" ) eq 'on';
            my $remote = param( "remote$_" ) eq 'on';
            my $hidden = param( "hidden$_" ) eq 'on';

            my $srole = $dbh->selectrow_array(
                qq~SELECT srole FROM accounts WHERE id IN (SELECT account_id FROM contest_accounts WHERE id=?)~, {}, $_
            );
            $jury = 1 if !$srole;

            $dbh->do(qq~UPDATE contest_accounts SET is_jury=?, is_hidden=?, is_remote=?, is_ooc=? WHERE id=?~, {},
                $jury, $hidden, $remote, $ooc, $_
            );
        }
        $dbh->commit;
    }

    if (defined param('register_new') && $is_jury)
    {
        users_register(param('login_to_register'));
    }
    
    if (defined param('send_message') && $is_jury)
    {                
        if (param('send_message_all') eq 'on')
        {
            users_send_broadcast(message => param('message_text'));                
        }
        else
        {
            users_send_message(user_set => param('user_set'), message => param('message_text'));
        }
        $dbh->commit;
    }

    my @cols;
    if ($is_jury)
    {
        @cols = ( { caption => res_str(616), order_by => '4', width => '15%' } );
    }

    push @cols,
      ( { caption => res_str(608), order_by => '5', width => '20%' } );

    if ($is_jury)
    {
        push @cols,
            (
              { caption => res_str(611), order_by => '6', width => '10%' },
              { caption => res_str(612), order_by => '7', width => '10%' },
              { caption => res_str(613), order_by => '8', width => '10%' },
              { caption => res_str(614), order_by => '9', width => '10%' } );
    }

    push @cols,
      ( { caption => res_str(607), order_by => '3', width => '10%' },
        { caption => res_str(609), order_by => '12', width => '10%' } );


    push @cols,
        ( { caption => res_str(632), order_by => '10', width => '10%' } );

    define_columns(url_f('users'), $is_jury ? 3 : 2, 1, [ @cols ] );


    my $c;
    if ($is_jury)
    {
        $c = $dbh->prepare(qq~
                   SELECT A.id, CA.id, A.country, A.login, A.team_name, 
                     CA.is_jury, CA.is_ooc, CA.is_remote, CA.is_hidden, CA.is_virtual, A.motto,
                     (SELECT COUNT(DISTINCT R.problem_id) FROM reqs R
                      WHERE R.state = $cats::st_accepted AND R.account_id=A.id AND R.contest_id=C.id)
                   FROM accounts A, contest_accounts CA, contests C
                   WHERE CA.account_id=A.id AND CA.contest_id=C.id AND C.id=?
                   ~.order_by);

        $c->execute($cid);
    }
    elsif ($is_team)
    {
        $c = $dbh->prepare(qq~
                   SELECT A.id, CA.id, A.country, A.login, A.team_name, 
                     CA.is_jury, CA.is_ooc, CA.is_remote, CA.is_hidden, CA.is_virtual, A.motto,
                     (SELECT COUNT(DISTINCT R.problem_id) FROM reqs R WHERE R.state = $cats::st_accepted AND R.account_id=A.id 
                      AND R.contest_id=C.id AND (R.submit_time < C.freeze_date OR R.submit_time > C.defreeze_date))
                   FROM accounts A, contest_accounts CA, contests C
                   WHERE CA.account_id=A.id AND CA.contest_id=C.id AND C.id=? AND CA.is_hidden=0 
                   ~.order_by);
                   
        $c->execute($cid);
    }
    else
    {
        $c = $dbh->prepare(qq~
                   SELECT A.id, CA.id, A.country, A.login, A.team_name, 
                     CA.is_jury, CA.is_ooc, CA.is_remote, CA.is_hidden, CA.is_virtual, A.motto, 
                     (SELECT COUNT(DISTINCT R.problem_id) FROM reqs R WHERE R.state = $cats::st_accepted AND R.account_id=A.id 
                      AND R.contest_id=C.id 
                      AND (R.submit_time < C.freeze_date OR R.submit_time > C.defreeze_date)) 
                   FROM accounts A, contest_accounts CA, contests C
                   WHERE C.id=? AND CA.account_id=A.id AND CA.contest_id=C.id AND CA.is_hidden=0
               ~.order_by);

        $c->execute($cid);
    }

    my $fetch_record = sub($)
    {            
        my (
            $aid, $caid, $country_abb, $login, $team_name, $jury, $ooc, $remote, $hidden, $virtual, $motto, $accepted
        ) = $_[0]->fetchrow_array
            or return ();
        my ( $country, $flag ) = get_flag( $country_abb );
        return ( 
            href_delete => url_f('users', delete => $caid),
            href_edit => url_f('users', edit => $aid),
            motto => $motto,
            id => $caid,
            login => $login, 
            editable => $is_jury,
            messages => $is_jury,
            team_name => $team_name,
            country => $country,
            flag => $flag,
            accepted => $accepted,
            jury => $jury,
            hidden => $hidden,
            ooc => $ooc,
            remote => $remote,
            virtual => $virtual
         );
    };
             
    attach_listview(url_f('users'), $fetch_record, $c);

    if ($is_jury)
    {
        my @submenu = ( { href_item => url_f('users', new => 1), item_name => res_str(541) } );
        $t->param(submenu => [ @submenu ] );    
    };

    $is_jury && $t->param(editable => 1);

    $c->finish;
}


sub registration_frame {

    init_template('main_registration.htm');

    $t->param(countries => [ @cats::countries ], href_login => url_f('login'));

    if (defined param('register'))
    {
        my $login = param('login');
        my $team_name = param('team_name');
        my $capitan_name = param('capitan_name');       
        my $email = param('email');     
        my $country = param('country'); 
        my $motto = param('motto');
        my $home_page = param('home_page');     
        my $icq_number = param('icq_number');
        my $password1 = param('password1');
        my $password2 = param('password2');

        unless ($login && length $login <= 100)
        {
            msg(101);
            return;
        }

        unless ($team_name && length $team_name <= 100)
        {
            msg(43);
            return;
        }

        if (length $capitan_name > 100)
        {
            msg(45);
            return;
        }

        if (length $motto > 200)
        {
            msg(44);
            return;
        }

        if (length $home_page > 100)
        {
            msg(48);
            return;
        }

        if (length $icq_number > 100)
        {
            msg(47);
            return;
        }

        if (length $password1 > 100)
        {
            msg(102);
            return;
        }          

        unless ($password1 eq $password2)
        {
            msg(33);
            return;
        }

        if ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM accounts WHERE login=?~, {}, $login))
        {
            msg(103);
            return;       
        }

        my $aid = new_id;
            
        $dbh->do(qq~INSERT INTO accounts (id, login, passwd, srole, team_name, capitan_name, country, motto, email, home_page, icq_number) 
            VALUES(?,?,?,?,?,?,?,?,?,?,?)~, {}, $aid, $login, $password1, $cats::srole_user, $team_name, $capitan_name, $country, $motto, $email, $home_page, $icq_number);

        my $c = $dbh->prepare(qq~SELECT id, closed FROM contests WHERE ctype=1~);
        $c->execute;
        while (my ($cid, $closed) = $c->fetchrow_array)
        {
            if ($closed)
            {
                msg(105);
                $dbh->rollback;
                return;
            }
            $dbh->do(qq~INSERT INTO contest_accounts (id, contest_id, account_id, is_jury, is_pop, is_hidden, is_ooc, is_remote) 
                VALUES(?,?,?,?,?,?,?,?)~, {}, new_id, $cid, $aid, 0, 0, 0, 1, 0);
        }
           
        $dbh->commit;
        $t->param(successfully_registred => 1);
    }
}


sub settings_save
{
    my $login = param('login');
    my $team_name = param('team_name');
    my $capitan_name = param('capitan_name');       
    my $email = param('email');     
    my $country = param('country'); 
    my $motto = param('motto');
    my $home_page = param('home_page');     
    my $icq_number = param('icq_number');
    my $set_password = param('set_password') eq 'on';
    my $password1 = param('password1');
    my $password2 = param('password2');

    unless ($login && length $login <= 100)
    {
        msg(101);
        return;
    }

    unless ($team_name && length $team_name <= 100)
    {
        msg(43);
        return;
    }

    if (length $capitan_name > 100)
    {
        msg(45);
        return;
    }

    if (length $motto > 500)
    {
        msg(44);
        return;
    }

    if (length $home_page > 100)
    {
        msg(48);
        return;
    }

    if (length $icq_number > 100)
    {
        msg(47);
        return;
    }

    if ($dbh->selectrow_array(qq~SELECT COUNT(*) FROM accounts WHERE id<>? AND login=?~, {}, $uid, $login))
    {
        msg(103);
        return;       
    }
 
    $dbh->do(qq~UPDATE accounts SET login=?, team_name=?, capitan_name=?, country=?, motto=?, email=?, home_page=?, icq_number=?
         WHERE id=?~, {}, $login, $team_name, $capitan_name, $country, $motto, $email, $home_page, $icq_number, $uid);

    $dbh->commit;       


    if ($set_password)
    {        
        if (length $password1 > 50)
        {
            msg(102);
            return;
        }

        unless ($password1 eq $password2)
        {
            msg(33);
            return;
        }
        
        $dbh->do(qq~UPDATE accounts SET passwd=? WHERE id=?~, {}, $password1, $uid);
        $dbh->commit; 
    }
}


sub settings_frame
{      
    init_template('main_settings.htm');

    if (defined param('edit_save') && $is_team)
    {
        settings_save;
    }

    my ($login, $team, $capitan, $motto, $country, $email, $home_page, $icq_number) = $dbh->selectrow_array(qq~
        SELECT login, team_name, capitan_name, motto, country, email, home_page, icq_number
        FROM accounts WHERE id=?~, {}, $uid);

    my $countries = [ @cats::countries ];

    foreach( @$countries ) 
    {
        $$_{selected} = $$_{id} eq $country;
    }

    $t->param(countries => $countries);

    $t->param(login => $login, href_action => url_f('users'),
            team => $team, capitan => $capitan, motto => $motto, country => $country, email => $email, 
            home_page => $home_page, icq_number => $icq_number);
}


sub compilers_new_frame
{
    init_template('main_compilers_new.htm');
    $t->param(href_action => url_f('compilers'));
}


sub compilers_new_save
{
    my $code = param('code');
    my $description = param('description');
    my $supported_ext = param('supported_ext');
    my $locked = param('locked') eq 'on';
            
    $dbh->do(qq~INSERT INTO default_de(id, code, description, file_ext, in_contests) VALUES(?,?,?,?,?)~, {}, 
             new_id, $code, $description, $supported_ext, !$locked);
    $dbh->commit;   
}


sub compilers_edit_frame
{
    init_template('main_compilers_edit.htm');

    my $id = url_param('edit');

    my( $code, $description, $supported_ext, $in_contests ) =
        $dbh->selectrow_array(qq~SELECT code, description, file_ext, in_contests FROM default_de WHERE id=?~, {}, $id);

    $t->param(id => $id,
              code => $code, 
              description => $description, 
              supported_ext => $supported_ext, 
              locked => !$in_contests,
              href_action => url_f('compilers'));
}


sub compilers_edit_save
{
    my $code = param('code');
    my $description = param('description');
    my $supported_ext = param('supported_ext');
    my $locked = param('locked') eq 'on';
    my $id = param('id');
            
    $dbh->do(qq~UPDATE default_de SET code=?, description=?, file_ext=?, in_contests=? WHERE id=?~, {}, 
             $code, $description, $supported_ext, !$locked, $id);
    $dbh->commit;   
}


sub compilers_frame 
{    
    return unless $is_jury;

    if (defined url_param('delete'))
    {
        my $deid = url_param('delete');
        $dbh->do(qq~DELETE FROM default_de WHERE id=?~, {}, $deid);
        $dbh->commit;       
    }

    if (defined url_param('new'))
    {        
        compilers_new_frame;
        return;
    };

    if (defined url_param('edit'))
    {        
        compilers_edit_frame;
        return;
    };


    init_listview_template( "compilers$cid" . ($uid || ''), 'compilers', 'main_compilers.htm' );      

    if (defined param('new_save'))       
    {
        compilers_new_save;
    }


    if (defined param('edit_save'))       
    {
        compilers_edit_save;
    }


    define_columns(url_f('compilers'), 0, 0, 
               [{ caption => res_str(619), order_by => '2', width => '10%' },
                { caption => res_str(620), order_by => '3', width => '40%' },
                { caption => res_str(621), order_by => '4', width => '10%' },
                { caption => res_str(622), order_by => '5', width => '10%' }]);

    my $c = $dbh->prepare(qq~SELECT id, code, description, file_ext, in_contests FROM default_de ~.order_by);
    $c->execute;

    my $fetch_record = sub($)
    {            
        if ( my( $did, $code, $description, $supported_ext, $in_contests ) = $_[0]->fetchrow_array)
        {                
            return ( 
                'did' => $did, 
                'code' => $code, 
                'description' => $description,
                'supported_ext' => $supported_ext,
                'locked' =>     !$in_contests,
                'href_edit' => url_f('compilers', edit => $did),
                'href_delete' => url_f('compilers', delete => $did)
            );
        }

        return ();
    };
             
    attach_listview(url_f('compilers'), $fetch_record, $c);

    if ($is_jury)
    {
        my @submenu = ( { href_item => url_f('compilers', new => 1), item_name => res_str(542) } );
        $t->param(submenu => [ @submenu ] );    
    };

    $is_jury && $t->param(editable => 1);

    $t->param(editable => 1);

    $c->finish;
}


sub judges_new_frame
{
    init_template('main_judges_new.htm');
    $t->param(href_action => url_f('judges'));
}


sub judges_new_save
{
    my $judge_name = param('judge_name');
    my $locked = param('locked') eq 'on';
    
    if ($judge_name eq '' || length $judge_name > 20)
    {
        msg 5;
        return;
    }
    
    $dbh->do(qq~INSERT INTO judges (id, nick, accept_contests, accept_trainings, lock_counter, alive_counter) VALUES(?,?,1,1,?,0)~, {}, 
            new_id, $judge_name, $locked ? -1 : 0);
    $dbh->commit;
}


sub judges_edit_frame
{
    init_template('main_judges_edit.htm');

    my $jid = url_param('edit');
    my ($judge_name, $lock_counter) = $dbh->selectrow_array(qq~SELECT nick, lock_counter FROM judges WHERE id=?~, {}, $jid);
    $t->param(id => $jid, judge_name => $judge_name, locked => $lock_counter, href_action => url_f('judges'));
}


sub judges_edit_save
{
    my $jid = param('id');
    my $judge_name = param('judge_name');
    my $locked = param('locked') eq 'on';
    
    if ($judge_name eq '' || length $judge_name > 20)
    {
        msg 5;
        return;
    }
  
    $dbh->do(qq~UPDATE judges SET nick=?, lock_counter=? WHERE id=?~, {}, 
            $judge_name, $locked ? -1 : 0, $jid);
    $dbh->commit;
}



sub judges_frame 
{
    return unless $is_jury;
 
    if (defined url_param('delete'))
    {
        my $jid = url_param('delete');
        $dbh->do(qq~DELETE FROM judges WHERE id=?~, {}, $jid);
        $dbh->commit;       
    }

    if (defined url_param('new'))
    {        
        judges_new_frame;
        return;
    };

    if (defined url_param('edit'))
    {        
        judges_edit_frame;
        return;
    };


    init_listview_template( "judges$cid" . ($uid || ''), 'judges', 'main_judges.htm' );      

    if (defined param('new_save'))
    {
        judges_new_save;
    }


    if (defined param('edit_save'))       
    {
        judges_edit_save;
    }


    define_columns(url_f('judges'), 0, 0, 
               [{ caption => res_str(625), order_by => '2', width => '80%' },
                { caption => res_str(626), order_by => '3', width => '10%' },
                { caption => res_str(627), order_by => '4', width => '10%' }]);

    my $c = $dbh->prepare(qq~SELECT id, nick, alive_counter, lock_counter FROM judges ~.order_by);
    $c->execute;

    my $fetch_record = sub($)
    {            
        if ( my( $jid, $judge_name, $alive_counter, $lock_counter ) = $_[0]->fetchrow_array)
        {                
            return ( 
                'jid' => $jid, 
                'judge_name' => $judge_name, 
                'locked' => $lock_counter,
                'alive_counter' => $alive_counter,
                'href_edit' => url_f('judges', edit => $jid),
                'href_delete' => url_f('judges', delete => $jid)
            );
        }

        return ();
    };
             
    attach_listview(url_f('judges'), $fetch_record, $c);

    my @submenu = ( { href_item => url_f('judges', new => 1), item_name => res_str(543) } );
    $t->param(submenu => [ @submenu ], editable => 1);

    $c->finish;
    
    $dbh->do(qq~UPDATE judges SET alive_counter=alive_counter+1~);
    $dbh->commit;
}


sub send_message_box_frame
{
    init_template('main_send_message_box.htm');
    return unless $is_jury;

    my $caid = url_param('caid');

    my $aid = $dbh->selectrow_array(qq~SELECT account_id FROM contest_accounts WHERE id=?~, {}, $caid);
    my $team = $dbh->selectrow_array(qq~SELECT team_name FROM accounts WHERE id=?~, {}, $aid);

    $t->param(team => $team);

    if (defined param('send'))
    {
        my $message_text = param('message_text');

        my $s = $dbh->prepare( qq~INSERT INTO messages (id, send_time, text, account_id, received) VALUES(?,CATS_SYSDATE(),?,?,0)~ );
        $s->bind_param(1, new_id );
        $s->bind_param(2, $message_text, { ora_type => 113 } );
        $s->bind_param(3, $caid);
        $s->execute;
        $dbh->commit;
        $t->param(sent => 1);
    }
}


sub answer_box_frame
{
    init_template('main_answer_box.htm');

    my $qid = url_param('qid');

    my $caid = $dbh->selectrow_array(qq~SELECT account_id FROM questions WHERE id=?~, {}, $qid);
    my $aid = $dbh->selectrow_array(qq~SELECT account_id FROM contest_accounts WHERE id=?~, {}, $caid);
    my $team_name = $dbh->selectrow_array(qq~SELECT login FROM accounts WHERE id=?~, {}, $aid);

    $t->param(team_name => $team_name);

    if (defined param('clarify'))
    {
        my $answer_text = param('answer_text');

        my $s = $dbh->prepare(qq~UPDATE questions SET clarification_time=CATS_SYSDATE(), answer=?, received=0, clarified=1 WHERE id=?~);
        $s->bind_param(1, $answer_text, { ora_type => 113 } );
        $s->bind_param(2, $qid);
        $s->execute;
        $dbh->commit;
        $t->param(clarified => 1);
    }
    else
    {
        my ( $submit_time, $question_text ) = 
            $dbh->selectrow_array(qq~SELECT CATS_DATE(submit_time), question FROM questions WHERE id=?~, {}, $qid);
    
        $t->param(submit_time => $submit_time, question_text => $question_text);
    }
}


sub run_details_frame
{
    console( 'main_run_details.htm' );
    my $rid = url_param('rid');

    my (
        $jid, $submit_time, $test_time, $result_time, $uid, $pid, $cid, $state
    ) = $dbh->selectrow_array(qq~
        SELECT judge_id, CATS_DATE(submit_time), CATS_DATE(test_time), CATS_DATE(result_time),
            account_id, problem_id, contest_id, state FROM reqs WHERE id=?~,
        {}, $rid
    );
   
    my $team_name = $dbh->selectrow_array(qq~SELECT team_name FROM accounts WHERE id=?~, {}, $uid);
    my $problem_name = $dbh->selectrow_array(qq~SELECT title FROM problems WHERE id=?~, {}, $pid);

    my $judge_name = '';
    if (defined $jid)
    {
        $judge_name = $dbh->selectrow_array(qq~SELECT nick FROM judges WHERE id=?~, {}, $jid);
    }

    my $contest = $dbh->selectrow_hashref(qq~
        SELECT
          title AS contest_name, run_all_tests,
          show_all_tests, show_test_resources, show_checker_comment
          FROM contests WHERE id=?~,
        { Slice => {} },
        $cid
    );
    my $jury_view = $is_jury && !url_param('as_user');
    $contest->{$_} ||= $jury_view for qw(show_all_tests show_test_resources show_checker_comment);
    
    my $points = [];
    if ($contest->{show_all_tests})
    {
        $points = $dbh->selectcol_arrayref(qq~
            SELECT points FROM tests WHERE problem_id = ? ORDER BY rank~,
            {}, $pid);
    }
    my $show_points = 0 != grep $_ > 0, @$points;

    $t->param(
        team_name => $team_name,
        problem_name => $problem_name,
        judge_name => $judge_name,
        submit_time => $submit_time,
        test_time => $test_time,
        result_time => $result_time,
        %$contest,
        show_points => $show_points,
        href_contest_problems => url_function('problems', cid => $cid, sid => $sid),
    );
    
    my %run_details;
    my $rd_fields = join ', ', (
         qw(test_rank result),
         ($contest->{show_test_resources} ? qw(time_used memory_used disk_used) : ()),
         ($contest->{show_checker_comment} ? qw(checker_comment) : ()),
    );
    
    my $c = $dbh->prepare(qq~SELECT $rd_fields FROM req_details WHERE req_id = ? ORDER BY test_rank~);
    $c->execute($rid);
    my $last_test = 0;
    
    while (my $row = $c->fetchrow_hashref())
    {
        my $prev_test = $last_test;
        my $accepted = $row->{result} == $cats::st_accepted;
        
        # �� ������, ���� � �� �� well-formed utf8
        if ($contest->{show_checker_comment})
        {
            my $d = $row->{checker_comment};
            $row->{checker_comment} = Encode::decode('utf8', $d, Encode::FB_QUIET);
            $row->{checker_comment} .= '...' if $d ne '';
        }
        
        $run_details{$last_test = $row->{test_rank}} =
        {
            state_to_display($row->{result}),
            map({ $_ => $contest->{$_} }
                qw(show_test_resources show_checker_comment)),
            %$row,
            show_points => $show_points,
            points => ($accepted ? $points->[$row->{test_rank} - 1] : 0),
        };
        # ����� ����������� � ��������� �������.
        # ���� �������� ���������� ������� ����������� � �������� ������������ �������,
        # �� ����� ������� ��������� 'OK' ��� ����� � �������, ������� ��� ������
        # �� ��������� ����. ������� ����� ����������� ���������� �� ������
        # �� ��������� ��� �� �ݣ ���������� �����.
        last if
            !$contest->{show_all_tests} &&
            (!$accepted || $prev_test != $last_test - 1); 
    }
    # �������� 'not processed' ��� ������, ������� ������ �� �����������.
    if ($contest->{show_all_tests} && !$contest->{run_all_tests})
    {
        $last_test = @$points;
    }
    $t->param(run_details => [
        map {
            exists $run_details{$_} ? $run_details{$_} :
            $contest->{show_all_tests} ? { test_rank => $_, not_processed => 1 } :
            () 
        } (1..$last_test)
    ]);
}


sub submit_details_frame
{
    console( "main_submit_details.htm" );   
    
    $is_jury or return;
    
    my $rid = url_param('rid');

    if ( defined param 'set_state' )
    {
        my $state = 
        {       
            not_processed =>            $cats::st_not_processed,
            accepted =>                 $cats::st_accepted,
            wrong_answer =>             $cats::st_wrong_answer,
            presentation_error =>       $cats::st_presentation_error,
            time_limit_exceeded =>      $cats::st_time_limit_exceeded,
            memory_limit_exceeded =>    $cats::st_memory_limit_exceeded,            
            runtime_error =>            $cats::st_runtime_error,
            compilation_error =>        $cats::st_compilation_error,
            security_violation =>       $cats::st_security_violation
        } -> { param 'state' };
                
        my $ftest = param('failed_test');       
       
        if (defined $state &&
            $dbh->do(qq~
                UPDATE reqs
                    SET failed_test=?, received=0, result_time=CATS_SYSDATE(), state=?, judge_id=NULL 
                    WHERE id=?~, {}, $ftest, $state, $rid
            ) &&
            $dbh->do(qq~DELETE FROM log_dumps WHERE req_id=?~, {}, $rid ))
        {
            $dbh->commit;
        }
    }

    my (
        $jid, $submit_time, $test_time, $result_time,
        $failed_test, $uid, $pid, $cid, $state
    ) = $dbh->selectrow_array(qq~
        SELECT
          judge_id, CATS_DATE(submit_time), CATS_DATE(test_time), CATS_DATE(result_time),
          failed_test, account_id, problem_id, contest_id, state
          FROM reqs WHERE id=?~, {},
        $rid
    );

    my $team_name = $dbh->selectrow_array(qq~SELECT team_name FROM accounts WHERE id=?~, {}, $uid);
    my $problem_name = $dbh->selectrow_array(qq~SELECT title FROM problems WHERE id=?~, {}, $pid);

    my $judge_name = '';
    if (defined $jid)
    {
        $judge_name = $dbh->selectrow_array(qq~SELECT nick FROM judges WHERE id=?~, {}, $jid);
    }

    my $contest_name = $dbh->selectrow_array(qq~SELECT title FROM contests WHERE id=?~, {}, $cid);

    $t->param(
        team_name => $team_name,
        problem_name => $problem_name,
        judge_name => $judge_name,
        submit_time => $submit_time,
        test_time => $test_time,
        result_time => $result_time,
        contest_name => $contest_name,
        href_contest_problems => url_function('problems', cid => $cid, sid => $sid),
        href_run_details => url_f('run_details', rid => $rid),
        failed_test_index => $failed_test,
        state_to_display($state),
    );

    my $previous_attempt = $dbh->selectrow_hashref(qq~
        SELECT id, CATS_DATE(submit_time) AS submit_time FROM reqs
          WHERE account_id = ? AND problem_id = ? AND contest_id = ? AND id < ?
          ORDER BY id DESC~, { Slice => {} },
        $uid, $pid, $cid, $rid
    );
    for ($previous_attempt)
    {
        last unless defined $_;
        $_->{submit_time} =~ s/\s*$//;
        $t->param(
            href_previous_attempt => url_f('submit_details', rid => $_->{id}),
            previous_attempt_time => $_->{submit_time},
            href_diff_runs => url_f('diff_runs', r1 => $_->{id}, r2 => $rid),
        );
    }

    if ( my ($dump) =
        $dbh->selectrow_array(qq~SELECT dump FROM log_dumps WHERE req_id=?~, {}, $rid ))
    {
        $t->param(judge_log_dump_avalaible => 1, judge_log_dump => Encode::decode('CP1251', $dump));  
    }

    my $c = $dbh->prepare(qq~SELECT rank FROM tests WHERE problem_id=? ORDER BY rank~);
    $c->execute($pid);

    my @tests;
    while ( my $t = $c->fetchrow_array )
    {
        push( @tests, { test_index => $t } );
    }

    $t->param( tests => [ @tests ] );

    if (my ($src, $fname, $de_id) =
        $dbh->selectrow_array( qq~SELECT src, fname, de_id FROM sources WHERE req_id=?~, {}, $rid ))
    {
        my $de = $dbh->selectrow_array( qq~SELECT description FROM default_de WHERE id=?~, {}, $de_id );

        $t->param(
            solution_code_avalaible => 1,
            solution_code => $src,
            de_name => $de,
            file_name => $fname );
    }
}


sub get_source_info
{
    my ($req_id) = @_ or return;
    
    my ($result) = $dbh->selectrow_hashref(qq~
        SELECT
          s.req_id, s.src, s.fname AS file_name,
          CATS_DATE(r.submit_time) AS submit_time,
          de.description AS de_name,
          a.team_name
          FROM sources s
            INNER JOIN reqs r ON r.id = s.req_id
            INNER JOIN default_de de ON de.id = s.de_id
            INNER JOIN accounts a ON a.id = r.account_id
          WHERE req_id = ?~, {},
        $req_id
    ) or return;
      
    $result->{lines} = [split "\n", $result->{src}];
    s/\s*$// for @{$result->{lines}};
    $result;
}


sub diff_runs_frame
{
    console('main_diff_runs.htm');
    $is_jury or return;
    
    my @sources_info = (1, 2);
    for (@sources_info)
    {
        $_ = get_source_info(param "r$_") or return;
    }
    
    my @diff = ();
    
    my $SL = sub { $sources_info[$_[0]]->{lines}->[$_[1]] }; 
    
    my $match = sub { push @diff, $SL->(0, $_[0]) . "\n"; };
    my $only_a = sub { push @diff, span({class=>'diff_only_a'}, $SL->(0, $_[0]) . "\n"); };
    my $only_b = sub { push @diff, span({class=>'diff_only_b'}, $SL->(1, $_[1]) . "\n"); };

    Algorithm::Diff::traverse_sequences(
        $sources_info[0]->{lines},
        $sources_info[1]->{lines},
        {
            MATCH     => $match,     # callback on identical lines
            DISCARD_A => $only_a,    # callback on A-only
            DISCARD_B => $only_b,    # callback on B-only
        }
    );

    $t->param(
        sources_info => \@sources_info,
        diff_lines => [map {line => $_}, @diff]
    );
}


sub rank_table
{
    my $template_name = shift;
    init_template('main_rank_table_content.htm');

    my $contest_title = $dbh->selectrow_array(qq~SELECT title FROM contests WHERE id=?~, {}, $cid);
    $t->param( contest_title => $contest_title );

    my $hide_ooc = url_param("hide_ooc") || '';
    unless ($hide_ooc =~ /^0$|^1$/)
    {
        $hide_ooc = 0;
    }

    my $hide_virtual = url_param("hide_virtual") || '';
    unless ($hide_virtual =~ /^0$|^1$/)
    {
        $hide_virtual = (!$is_virtual && !$is_jury || !$is_team);
    }


    # ��������������� ����������: � ����� ���������� ������ �� ������ ������������� ��������������
    # ��� ������ UNIQUE(c,p)
    my $c = $dbh->prepare(qq~SELECT problem_id, code FROM contest_problems WHERE contest_id=? ORDER BY code~);
    $c->execute($cid);
    
    my ( @p_id, @problems );
    
    while ( my ( $problem_id, $pcode ) = $c->fetchrow_array ) {
        push @problems, { code => $pcode };
        push @p_id, $problem_id;
    }
    $c->finish;
    
    $t->param( problems => [ @problems ] );

    my @rank;
    my $nteams = 0;

    my $c2 = $dbh->prepare(qq~SELECT team_name, motto, country, B.id, 
                            B.account_id, is_virtual, is_ooc, is_remote 
                            FROM accounts A, contest_accounts B
                            WHERE contest_id=? AND A.id=B.account_id AND is_hidden=0~);     
    $c2->execute($cid);    


    my $frozen = $dbh->selectrow_array(qq~
        SELECT 1 FROM contests WHERE id=? AND CATS_SYSDATE() > freeze_date AND CATS_SYSDATE() < defreeze_date~, {},
        $cid);

    $t->param( 
        frozen => $frozen,
        hide_ooc => !$hide_ooc,
        hide_virtual => !$hide_virtual,
        href_hide_ooc => url_f('rank_table', hide_ooc => 1, hide_virtual => $hide_virtual),
        href_show_ooc => url_f('rank_table', hide_ooc => 0, hide_virtual => $hide_virtual),
        href_hide_virtual => url_f('rank_table', hide_virtual => 1, hide_ooc => $hide_ooc),
        href_show_virtual => url_f('rank_table', hide_virtual => 0, hide_ooc => $hide_ooc) );

    while (my ($team_name, $motto, $country_abb, $caid, $aid, $virtual, $ooc, $remote) = $c2->fetchrow_array) 
    {
        next if ($hide_ooc && $ooc || $hide_virtual && $virtual);
        
        my $c3;        
        if ($is_jury)
        {
            $c3 = $dbh->prepare(qq~SELECT R.state, ((R.submit_time - C.start_date - CA.diff_time) * 1440), R.problem_id 
                FROM reqs R, contests C, contest_accounts CA WHERE R.state>=? AND C.id=? AND R.contest_id=C.id 
                AND R.account_id=? AND CA.contest_id=C.id AND CA.account_id=R.account_id ORDER BY R.id~);
            $c3->execute($cats::request_processed, $cid, $aid);

        }
        elsif ($is_team)
        {
            $c3 = $dbh->prepare(qq~SELECT R.state, ((R.submit_time - C.start_date - CA.diff_time) * 1440), R.problem_id 
                FROM reqs R, contests C, contest_accounts CA WHERE R.state>=? AND C.id=? AND R.contest_id=C.id 
                AND R.account_id=? AND (R.account_id=? OR ((R.submit_time < C.freeze_date) OR (CATS_SYSDATE() > C.defreeze_date)))
                AND CA.contest_id=C.id AND CA.account_id=R.account_id
                AND (R.submit_time - CA.diff_time < CATS_SYSDATE() - $virtual_diff_time)
                ORDER BY R.id~);
            $c3->execute($cats::request_processed, $cid, $aid, $uid);

        }
        else
        {
            $c3 = $dbh->prepare(qq~SELECT R.state, ((R.submit_time - C.start_date - CA.diff_time) * 1440), R.problem_id 
                FROM reqs R, contests C, contest_accounts CA WHERE R.state>=? AND C.id=? AND R.contest_id=C.id 
                AND R.account_id=? AND ((R.submit_time < C.freeze_date) OR (CATS_SYSDATE() > C.defreeze_date))          
                AND CA.contest_id=C.id AND CA.account_id=R.account_id
                ORDER BY R.id~);
            $c3->execute($cats::request_processed, $cid, $aid);
        }

        my ( $country, $flag ) = get_flag( $country_abb );
        
        my %r = ( team_name => $team_name, 
		    # ��������� ����������� �������� ������ ooc, �� ������� ������ �������
            ooc => ($virtual ? 0 : $ooc), 
            remote => $remote, 
            virtual => $virtual,
            solved => 0,
            submissions => 0,
            ftime => 0,
            time => 0,
            aid => $aid,
            country => $country,
            flag => $flag,
            motto => $motto
        );
        
        foreach (@p_id) { $r{$_} = 0; }
        while (my ($state, $time, $problem_id) = $c3->fetchrow_array) 
        {
            $r{"r$problem_id"} ||= 0;
            if ($r{"r$problem_id"} <= 0)
            {
                if ( $state == $cats::st_accepted ) 
                { 
                    $r{ "r$problem_id" } = abs($r{ "r$problem_id" }) + 1;
                    $r{ "t$problem_id" } = int($time + 0.5) + ($r{ "r$problem_id" } - 1) * $cats::penalty;
                    $r{ time } += $r{ "t$problem_id" };
                    $r{ solved }++;
                }
                elsif ($state != $cats::st_security_violation) 
                {
                    $r{ "r$problem_id" }--;
                    $r{ submissions }++;
                }
            }
        }
        
        $c3->finish;

        push @rank, { %r };
        $nteams++;
    }
    $c2->finish;

    @rank = sort { $$b{ solved } <=> $$a{ solved } || $$a{ time } <=> $$b{ time } 
        || $$b{ submissions } <=> $$a{ submissions } } @rank;
    
    my ($ptime, $psolved, $place, $i, $row_color) = (1000000000, -1, 1, 0, 0);
    
    for (@rank)
    {
        my $r = $_;
        my @columns = ();
        
        foreach (@p_id)
        {
            my $c = $r -> { "r$_" };

            if (!defined $c || !$c) { $c = "." }
            elsif ($c == 1) { $c = "+" }
            elsif ($c >= 0) { $c = "+".($c-1); }

            push( @columns, { td => $c, time => $r -> { "t$_" } } );        
        }

	$row_color = 1 - $row_color if $psolved > $r -> { solved };	
        $place++ if ( $psolved > $r -> { solved } || $ptime < $r -> { time } ); 
        $psolved = $r -> { solved };
        $ptime = $r -> { time };


	$r -> { row_color } = $row_color;
        $r -> { contestant_number } = ++$i;
        $r -> { place } = $place;       
        $r -> { columns } = [ @columns ];

    }    

    $t->param ( rank => [ @rank ] );


    my $s = $t->output;

    init_template($template_name);  
    $t->param(rank_table_content => $s);
}


sub rank_table_frame
{
    my $hide_ooc = url_param('hide_ooc') || 0;
    my $hide_virtual = url_param('hide_virtual') || 0;
    
    #rank_table( "main_rank_table.htm" );  
    init_template('main_rank_table.htm');  
        
    $t->param(href_rank_table_content => 
        url_f('rank_table_content', hide_ooc => $hide_ooc, hide_virtual => $hide_virtual));
}


sub rank_table_content_frame
{
    rank_table('main_rank_table_iframe.htm');  
}


# ��������� �������� � ������� �����
sub start_element 
{
    my ($el, %atts) = @_;

    $html_code .= "<$el";
    foreach my $name (keys %atts)
    {
        $name = $name;
        my $attrib = $atts{$name};

        $html_code .= " $name=\"$attrib\"";
    }
    $html_code .= ">";
}


sub end_element 
{
    my ( $el ) = @_;    

    $html_code .= "</$el>";
}


sub text
{
    my ( $text ) = shift;
    
    $html_code .= $text;
}


sub ch_1
{
    my ( $p, $text ) = @_;
        
    text( $text );
}


sub download_image
{
    my $id = shift;

    my $download_dir = './download';

    my ( $pic, $ext ) = $dbh->selectrow_array(qq~SELECT pic, extension FROM pictures WHERE id=?~, {}, $id );

    my ( $fh, $fname ) = tempfile( 
        "img_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", 
        DIR => $download_dir, SUFFIX => ".$ext" );

    binmode(STDOUT, ':raw');

    syswrite($fh, $pic, length($pic));    

    close $fh;
    
    return $fname;
}

sub sh_1
{
    my ( $p, $el, %atts ) = @_;
    
    if ($el eq 'img' && $atts{'picture'})
    {
        my ( $id ) = $dbh->selectrow_array( qq~SELECT id FROM pictures WHERE problem_id=? AND name=?~, 
            {}, $current_pid, $atts{'picture'} );
        
        $atts{ 'src' } = download_image($id);
        delete $atts{'picture'};
    }
    start_element( $el, %atts );
}


sub eh_1
{
    my ( $p, $el ) = @_;
    end_element( $el );
} 


sub parse {
    
    my $xml_patch = shift;
    
    my $parser = new XML::Parser::Expat;

    $html_code = "";

    $parser->setHandlers(
        'Start' => \&sh_1,
        'End'   => \&eh_1,
        'Char'  => \&ch_1);
                
    $parser->parse( "<p>$xml_patch</p>" );
    return $html_code;    
}


sub contest_visible 
{  
    my $contest_visible = 0;

    my $pid = url_param('pid');
    my $cpid = url_param('cpid');

    if (defined $pid)
    {
        $contest_visible =
            $is_jury || $dbh->selectrow_array(
                qq~SELECT CATS_SYSDATE() - B.start_date
                    FROM problems A, contests B 
                    WHERE A.id=? AND B.id = A.contest_id~, {}, $pid) > 0;
    }
    elsif (defined $cpid)
    {
        $contest_visible =
            $is_jury || $dbh->selectrow_array(
                qq~SELECT CATS_SYSDATE() - B.start_date
                    FROM contest_problems A, contests B 
                    WHERE A.id=? AND B.id = A.contest_id~, {}, $cpid) > 0;
    
    }
    elsif (defined $cid)
    {
        $contest_visible = 
            $is_jury || $dbh->selectrow_array(
                qq~SELECT CATS_SYSDATE() - A.start_date FROM contests A WHERE A.id=?~, {}, $cid) > 0;
    }

    if (!$contest_visible)
    {
        init_template('main_access_denied.htm');
        return 0;
    }
    1;
}    


sub problem_text_frame
{
    return if (!contest_visible);

    init_template("main_problem_text.htm");

    my ( @id_problems, @problems, %pcodes );
    
    my $pid = url_param('pid');
    my $cpid = url_param('cpid');

    if ( defined $pid )
    {
        push @id_problems, $pid;
    }
    elsif ( defined $cpid )
    {
        my ( $contest_title, $problem_id, $code ) = 
            $dbh->selectrow_array(qq~SELECT A.title, B.problem_id, B.code FROM contests A, contest_problems B
                                     WHERE B.id=? AND B.contest_id=A.id~, {}, $cpid);    
      
        push @id_problems, $problem_id;
        $pcodes{ $problem_id } = $code;
    }
    else
    {    
        my $c = $dbh->prepare( qq~SELECT problem_id, code FROM contest_problems WHERE contest_id=? ORDER BY code~ );

        $c->execute( $cid );
        while ( my ( $problem_id, $code ) = $c->fetchrow_array )
        {
            push @id_problems, $problem_id;
            $pcodes{ $problem_id } = $code;
        }
    }


    foreach my $problem_id ( @id_problems )
    {
        $current_pid = $problem_id;
        
        my ( $problem_name, $lang, $difficulty, $author, $input_file, $output_file,
            $statement, $constraints, $input_format, $output_format, $time_limit, $memory_limit )
                = $dbh->selectrow_array( qq~SELECT title, lang, difficulty, author, input_file, output_file,
                    statement, pconstraints, input_format, output_format, time_limit, memory_limit  
                    FROM problems WHERE id=?~, {}, $problem_id );
        


        my $x;
        foreach ( 'ru', 'en' )
        {
            $x = $_;
            last if ($lang eq $_);
        }

        my $c = $dbh->prepare( qq~SELECT rank, in_file, out_file FROM samples WHERE problem_id=? ORDER BY rank~ );
        $c->execute( $problem_id );
    
        my @samples;
    
        while (my ( $rank, $test_in, $test_out ) = $c->fetchrow_array )
        {
            push ( @samples, { rank => $rank, test_in => $test_in, test_out => $test_out } );
        }



        push @problems,  {
            problem_name => $problem_name,
            code => $pcodes{ $problem_id },
            author => $author,          
            input_file => $input_file,
            output_file => $output_file,
            time_limit => $time_limit,
            memory_limit => $memory_limit,
            statement => ($statement ne '') ? Encode::encode_utf8( parse( $statement ) ) : undef,
            constraints => $constraints ? Encode::encode_utf8( parse( $constraints ) ) : undef,
            input_format => ($input_format ne '') ? Encode::encode_utf8( parse( $input_format ) ) : undef, 
            output_format => ($output_format ne '') ? Encode::encode_utf8( parse( $output_format ) ) : undef,  
            lang_ru => $x eq 'ru',
            lang_en => $x eq 'en',
            samples => [ @samples ]
        };
    }    


    $t->param(problems => [ @problems ]);
}


sub envelope_frame
{
    init_template('main_envelope.htm');
    
    my $rid = url_param('rid');

    my ($submit_time, $test_time, $state, $failed_test, $team_name, $contest_title) = $dbh->selectrow_array(qq~
        SELECT CATS_DATE(R.submit_time), CATS_DATE(R.test_time), R.state, R.failed_test, A.team_name, C.title
            FROM reqs R, contests C, accounts A
            WHERE R.id=? AND A.id=R.account_id AND C.id=R.contest_id~, {}, $rid);
    $t->param(
        submit_time => $submit_time,
        test_time => $test_time,
        team_name => $team_name,
        contest_title => $contest_title,
        failed_test_index => $failed_test,
        state_to_display($state)
    );
}


sub about_frame
{
    init_template('main_about.htm');
    my $problem_count = $dbh->selectrow_array(qq~SELECT COUNT(*) FROM problems~);
    $t->param(problem_count => $problem_count);
}

sub generate_menu
{
    my $logged_on = $sid ne '';
  
    my @left_menu = (
        { item => $logged_on ? res_str(503) : res_str(500), 
          href => $logged_on ? url_function('logout', sid => $sid) : url_f('login') },
        { item => res_str(502), href => url_f('contests') }
    );   

    push @left_menu,       
      ( { item => res_str(525), href => url_f('problems') },
        { item => res_str(526), href => url_f('users'   ) },
        { item => res_str(510), href => url_f('console' ) } );

    if ($is_jury)
    {
        push @left_menu, (
            { item => res_str(517), href => url_f('compilers') },
            { item => res_str(511), href => url_f('judges') } );
    }

    if (!$is_practice)
    {
        push @left_menu, ( { item => res_str(529), href => url_f('rank_table') } );

    }

    my @right_menu = ();

    if ($is_team && (url_param('f') ne 'logout'))
    {
        @right_menu = ( { item => res_str(518), href => url_f('settings') } );
    }
    
    push @right_menu,
        (       
        { item => res_str(544), href => url_f('about') },
        { item => res_str(501), href => url_f('registration') } );

    attach_menu( "left_menu", undef, [ @left_menu ] );
    attach_menu( "right_menu", "about", [ @right_menu ] );
}


sub interface_functions ()
{
    {
        login => \&login_frame,
        logout => \&logout_frame,
        registration => \&registration_frame,
        settings => \&settings_frame,
        contests => \&contests_frame,
        console_content => \&console_content_frame,
        console => \&console_frame,
        problems => \&problems_frame,
        users => \&users_frame,
        compilers => \&compilers_frame,
        judges => \&judges_frame,
        answer_box => \&answer_box_frame,
        send_message_box => \&send_message_box_frame,
        submit_details => \&submit_details_frame,
        rank_table_content => \&rank_table_content_frame,
        rank_table => \&rank_table_frame,
        problem_text => \&problem_text_frame,
        envelope => \&envelope_frame,
        about => \&about_frame,
        run_details => \&run_details_frame,
        diff_runs => \&diff_runs_frame,
    }
}


sub accept_request                                               
{     
    initialize;

    my $function_name = url_param('f') || '';
    my $fn = interface_functions()->{$function_name} || \&about_frame;
    $fn->();

    generate_menu if (defined $t);
    generate_output;

    $dbh->rollback;
}
         

sql_connect;

#while(CGI::Fast->new)
#{  
#    accept_request;    
#    exit if (-M $ENV{ SCRIPT_FILENAME } < 0); 
#}

accept_request;    
   
sql_disconnect;

1;
   

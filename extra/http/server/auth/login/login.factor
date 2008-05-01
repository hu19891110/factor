! Copyright (c) 2008 Slava Pestov
! See http://factorcode.org/license.txt for BSD license.
USING: accessors quotations assocs kernel splitting
base64 io combinators sequences io.files namespaces hashtables
fry io.sockets arrays threads locals qualified continuations
destructors

html.elements
http
http.server
http.server.auth
http.server.auth.providers
http.server.auth.providers.null
http.server.actions
http.server.components
http.server.flows
http.server.forms
http.server.sessions
http.server.boilerplate
http.server.templating
http.server.templating.chloe
http.server.validators ;
IN: http.server.auth.login
QUALIFIED: smtp

SYMBOL: login-failed?

TUPLE: login < dispatcher users ;

: users login get users>> ;

! Destructor
TUPLE: user-saver user ;

C: <user-saver> user-saver

M: user-saver dispose
    user>> dup changed?>> [ users update-user ] [ drop ] if ;

: save-user-after ( user -- )
    <user-saver> add-always-destructor ;

: login-template ( name -- template )
    "resource:extra/http/server/auth/login/" swap ".xml"
    3append <chloe> ;

! ! ! Login

: <login-form>
    "login" <form>
        "login" login-template >>edit-template
        "username" <username>
            t >>required
            add-field
        "password" <password>
            t >>required
            add-field ;

: successful-login ( user -- response )
    username>> set-uid
    "$login" end-flow ;

:: <login-action> ( -- action )
    [let | form [ <login-form> ] |
        <action>
            [ blank-values ] >>init

            [ form edit-form ] >>display

            [
                blank-values

                form validate-form

                "password" value "username" value
                users check-login [
                    successful-login
                ] [
                    login-failed? on
                    validation-failed
                ] if*
            ] >>submit
    ] ;

! ! ! New user registration

: <register-form> ( -- form )
    "register" <form>
        "register" login-template >>edit-template
        "username" <username>
            t >>required
            add-field
        "realname" <string> add-field
        "new-password" <password>
            t >>required
            add-field
        "verify-password" <password>
            t >>required
            add-field
        "email" <email> add-field
        "captcha" <captcha> add-field ;

SYMBOL: password-mismatch?
SYMBOL: user-exists?

: same-password-twice ( -- )
    "new-password" value "verify-password" value = [ 
        password-mismatch? on
        validation-failed
    ] unless ;

:: <register-action> ( -- action )
    [let | form [ <register-form> ] |
        <action>
            [ blank-values ] >>init

            [ form edit-form ] >>display

            [
                blank-values

                form validate-form

                same-password-twice

                "username" value <user>
                    "realname" value >>realname
                    "new-password" value >>password
                    "email" value >>email
                    H{ } clone >>profile

                users new-user [
                    user-exists? on
                    validation-failed
                ] unless*

                successful-login

                login get init-user-profile
            ] >>submit
    ] ;

! ! ! Editing user profile

: <edit-profile-form> ( -- form )
    "edit-profile" <form>
        "edit-profile" login-template >>edit-template
        "username" <username> add-field
        "realname" <string> add-field
        "password" <password> add-field
        "new-password" <password> add-field
        "verify-password" <password> add-field
        "email" <email> add-field ;

:: <edit-profile-action> ( -- action )
    [let | form [ <edit-profile-form> ] |
        <action>
            [
                blank-values

                logged-in-user get
                [ username>> "username" set-value ]
                [ realname>> "realname" set-value ]
                [ email>> "email" set-value ]
                tri
            ] >>init

            [ form edit-form ] >>display

            [
                blank-values
                uid "username" set-value

                form validate-form

                logged-in-user get

                { "password" "new-password" "verify-password" }
                [ value empty? ] all? [
                    same-password-twice

                    "password" value uid users check-login
                    [ login-failed? on validation-failed ] unless

                    "new-password" value >>password
                ] unless

                "realname" value >>realname
                "email" value >>email

                t >>changed?

                drop

                "$login" end-flow
            ] >>submit
    ] ;

! ! ! Password recovery

SYMBOL: lost-password-from

: current-host ( -- string )
    request get host>> host-name or ;

: new-password-url ( user -- url )
    "new-password"
    swap [
        [ username>> "username" set ]
        [ ticket>> "ticket" set ]
        bi
    ] H{ } make-assoc
    derive-url ;

: password-email ( user -- email )
    smtp:<email>
        [ "[ " % current-host % " ] password recovery" % ] "" make >>subject
        lost-password-from get >>from
        over email>> 1array >>to
        [
            "This e-mail was sent by the application server on " % current-host % "\n" %
            "because somebody, maybe you, clicked on a ``recover password'' link in the\n" %
            "login form, and requested a new password for the user named ``" %
            over username>> % "''.\n" %
            "\n" %
            "If you believe that this request was legitimate, you may click the below link in\n" %
            "your browser to set a new password for your account:\n" %
            "\n" %
            swap new-password-url %
            "\n\n" %
            "Love,\n" %
            "\n" %
            "  FactorBot\n" %
        ] "" make >>body ;

: send-password-email ( user -- )
    '[ , password-email smtp:send-email ]
    "E-mail send thread" spawn drop ;

: <recover-form-1> ( -- form )
    "register" <form>
        "recover-1" login-template >>edit-template
        "username" <username>
            t >>required
            add-field
        "email" <email>
            t >>required
            add-field
        "captcha" <captcha> add-field ;

:: <recover-action-1> ( -- action )
    [let | form [ <recover-form-1> ] |
        <action>
            [ blank-values ] >>init

            [ form edit-form ] >>display

            [
                blank-values

                form validate-form

                "email" value "username" value
                users issue-ticket [
                    send-password-email
                ] when*

                "recover-2" login-template serve-template
            ] >>submit
    ] ;

: <recover-form-3>
    "new-password" <form>
        "recover-3" login-template >>edit-template
        "username" <username>
            hidden >>renderer
            t >>required
            add-field
        "new-password" <password>
            t >>required
            add-field
        "verify-password" <password>
            t >>required
            add-field
        "ticket" <string>
            hidden >>renderer
            t >>required
            add-field ;

:: <recover-action-3> ( -- action )
    [let | form [ <recover-form-3> ] |
        <action>
            [
                { "username" [ v-required ] }
                { "ticket" [ v-required ] }
            ] >>get-params

            [
                [
                    "username" [ get ] keep set
                    "ticket" [ get ] keep set
                ] H{ } make-assoc values set
            ] >>init

            [ <recover-form-3> edit-form ] >>display

            [
                blank-values

                form validate-form

                same-password-twice

                "ticket" value
                "username" value
                users claim-ticket [
                    "new-password" value >>password
                    users update-user

                    "recover-4" login-template serve-template
                ] [
                    <400>
                ] if*
            ] >>submit
    ] ;

! ! ! Logout
: <logout-action> ( -- action )
    <action>
        [
            f set-uid
            "$login/login" end-flow
        ] >>submit ;

! ! ! Authentication logic

TUPLE: protected < filter-responder ;

C: <protected> protected

: show-login-page ( -- response )
    begin-flow
    "$login/login" f <standard-redirect> ;

M: protected call-responder* ( path responder -- response )
    uid dup [
        users get-user
        [ logged-in-user set ] [ save-user-after ] bi
        call-next-method
    ] [
        3drop show-login-page
    ] if ;

M: login call-responder* ( path responder -- response )
    dup login set
    call-next-method ;

: <login-boilerplate> ( responder -- responder' )
    <boilerplate>
        "boilerplate" login-template >>template ;

: <login> ( responder -- auth )
    login new-dispatcher
        swap >>default
        <login-action> <login-boilerplate> "login" add-responder
        <logout-action> <login-boilerplate> "logout" add-responder
        no-users >>users ;

! ! ! Configuration

: allow-edit-profile ( login -- login )
    <edit-profile-action> <protected> <login-boilerplate>
        "edit-profile" add-responder ;

: allow-registration ( login -- login )
    <register-action> <login-boilerplate>
        "register" add-responder ;

: allow-password-recovery ( login -- login )
    <recover-action-1> <login-boilerplate>
        "recover-password" add-responder
    <recover-action-3> <login-boilerplate>
        "new-password" add-responder ;

: allow-edit-profile? ( -- ? )
    login get responders>> "edit-profile" swap key? ;

: allow-registration? ( -- ? )
    login get responders>> "register" swap key? ;

: allow-password-recovery? ( -- ? )
    login get responders>> "recover-password" swap key? ;

-- Static script. Every user value is passed as an Apple-event list item, never
-- interpolated into source code. Only draft operations are exposed. NO SEND.
on attachmentInfo(theMessage)
    tell application id "com.microsoft.Outlook"
        set resultRows to {}
        repeat with a in attachments of theMessage
            set end of resultRows to {name of a as text, file size of a as integer}
        end repeat
        return resultRows
    end tell
end attachmentInfo

on checkedSource(args)
    set sourceID to (item 2 of args) as integer
    set expectedHeaders to item 3 of args
    set expectedSubject to item 4 of args
    tell application id "com.microsoft.Outlook"
        set sourceMessage to message id sourceID
        if (headers of sourceMessage as text) is not expectedHeaders then error "SOURCE_CHANGED" number -9002
        if (subject of sourceMessage as text) is not expectedSubject then error "SOURCE_CHANGED" number -9002
        if is partially downloaded of sourceMessage then error "SOURCE_NOT_DOWNLOADED" number -9003
        if is rights protected of sourceMessage then error "SOURCE_PROTECTED" number -9004
        return sourceMessage
    end tell
end checkedSource

on readDraft(draftID)
    tell application id "com.microsoft.Outlook"
        set d to outgoing message id (draftID as integer)
        if was sent of d then error "NOT_A_DRAFT" number -9005
        return {id of d as text, subject of d as text, content of d as text, plain text content of d as text, my attachmentInfo(d), has html of d}
    end tell
end readDraft

on run args
    with timeout of 20 seconds
        set actionName to item 1 of args
        if actionName is "capture" then
            tell application id "com.microsoft.Outlook"
                set selectedMessages to current messages
                if (count of selectedMessages) is not 1 then error "SELECT_ONE_MESSAGE" number -9001
                set m to item 1 of selectedMessages
                if class of m is outgoing message then
                    if not (was sent of m) then error "SELECT_ORIGINAL_NOT_DRAFT" number -9001
                end if
                return {id of m as text, headers of m as text, subject of m as text, plain text content of m as text}
            end tell
        else if actionName is "validate" then
            my checkedSource(args)
            return true
        else if actionName is "sourceAttachments" then
            return my attachmentInfo(my checkedSource(args))
        else if actionName is "create" then
            set modeName to item 5 of args
            if modeName is not "newMail" then set m to my checkedSource(args)
            tell application id "com.microsoft.Outlook"
                if modeName is "newMail" then
                    set d to make new outgoing message with properties {subject:"", content:""}
                else if modeName is "reply" then
                    set d to reply to m opening window false reply to all false
                else if modeName is "replyAll" then
                    set d to reply to m opening window false reply to all true
                else if modeName is "forward" then
                    set d to forward m opening window false
                else
                    error "UNKNOWN_MODE" number -9006
                end if
                save d
                return id of d as text
            end tell
        else if actionName is "read" then
            return my readDraft(item 2 of args)
        else if actionName is "apply" then
            set draftID to item 2 of args
            set beforeSnapshot to my readDraft(draftID)
            -- Do not overwrite concurrent user edits. The exact target is a
            -- native message ID; the foreground app/window is irrelevant.
            if item 2 of beforeSnapshot is not item 3 of args then error "DRAFT_CHANGED" number -9007
            if item 3 of beforeSnapshot is not item 4 of args then error "DRAFT_CHANGED" number -9007
            if item 4 of beforeSnapshot is not item 5 of args then error "DRAFT_CHANGED" number -9007
            if item 5 of beforeSnapshot is not item 6 of args then error "ATTACHMENTS_CHANGED" number -9007
            tell application id "com.microsoft.Outlook"
                set d to outgoing message id (draftID as integer)
                set subject of d to item 7 of args
                set content of d to item 8 of args
                set reminderAddress to item 9 of args
                if reminderAddress is not "" then
                    set alreadyThere to false
                    repeat with r in bcc recipients of d
                        if address of email address of r is reminderAddress then set alreadyThere to true
                    end repeat
                    if not alreadyThere then make new bcc recipient at d with properties {email address:{address:reminderAddress}}
                end if
                save d
                return true
            end tell
        else if actionName is "reveal" then
            tell application id "com.microsoft.Outlook"
                set d to outgoing message id ((item 2 of args) as integer)
                if was sent of d then error "NOT_A_DRAFT" number -9005
                open d
                activate
            end tell
            return true
        else
            error "UNKNOWN_ACTION" number -9006
        end if
    end timeout
end run

import macros
import strutils
import parseutils
import strformat, strutils
import asyncdispatch
import strscans
import std/with
import dimscord
import sugar
import macroUtils
import parsing

# TODO, learn to write better documentation
## Commands are registered using with the .command. pragma or the .slashcommand. pragma.
## The .command. pragma is used for creating commands that the bot responds to in chat.
## The .slashcommand. pragma is used for creating commands that the bot responds to when using slash commands.
##
## If you are using slash commands then you must register the commands.
## This is done in your bots onReady event like so.
##
## ..code-block ::
##    proc onReady (s: Shard, r: Ready) {.event(discord).} =
##        await discord.api.registerCommands("742010764302221334") # You must pass your application ID which is found on your bots dashboard
##        echo "Ready as " & $r.user
##
## An issue with pragmas is that you cannot have optional parameters (or I am not smart enough to know how) and so this library uses the
## doc string of a procedure to provide further config. These are called doc options and are used like so
##
## .. code-block::
##    proc procThatYouWantToProvideOptionsFor() {.command.} =
##        ## $name: value # Variable must start with $
##        discard    


type
    CommandType = enum
        ## A chat command is a command that is sent to the bot over chat
        ## A slash command is a command that is sent using the slash commands functionality in discord
        ctChatCommand
        ctSlashCommand
        
    Command = object
        name: string
        kind: CommandType              
        prc: NimNode
        # The approach of storing NimNode and building the code for later works nice and plays nicely with unittesting
        # But it doesn't seem the cleanest I understand
        # For now though I will keep it like this until I see how slash commands are implemented in dimscord
        help: string
        parameters: seq[ProcParameter]

    SlashCommand = object
        ## This is used at runtime to register all the slash commands
        name: string
        description: string
        guildID: string ## Leave blank for global
        options: seq[ApplicationCommandOption]

# A global variable is not a good idea but it works well
var 
    dimscordCommands {.compileTime.}: seq[Command]
    dimscordSlashCommands*: seq[SlashCommand]

# const runtimeDimscordSlashCommands* = dimscordSlashCommands
    
proc command(prc: NimNode, name: string) =
    ## **INTERNAL**
    ## This is called by the `command` pragmas
    var newCommand: Command
    with newCommand:
        # Set the name of the command
        name = name
        # Set the help message
        help = prc.getDocNoOptions()
        # Set the types
        parameters = prc.getParameters()
        # Add the code
        prc = prc.body()
        kind = ctChatCommand
    dimscordCommands.add newCommand

proc registerSlashProc(prc: NimNode, name: string, guildID: string = ""): NimNode =
    ## Adds the code to register the slash command
    let description = newStrLitNode(prc.getDocNoOptions())
    return quote do:
        dimscordSlashCommands.add SlashCommand(
            name: `name`,
            description: `description`,
            guildID: `guildID`
        )

proc slashCommand(prc: NimNode, name: string, guildID = ""): NimNode =
    return registerSlashProc(prc, name, guildID)

macro slashCommand*(prc: untyped) =
    ## Use this pragma to add a slash command
    ## .. code-block::
    ##    proc ping() {.slashcommand.} =
    ##        # TODO add ping command
    ##
    ## By default the command uses the name of the proc has the command name e.g. the command defined before will be called ping.
    ## If you wish to give the command a different name then you must use the doc option $name or you can give it a specific guildID with $guildID
    ##
    ## .. code-block::
    ##    proc genericCommand() {.slashcommand.} =
    ##        ## $name: ping
    ##        ## $guildID: 1234556789
    ##        # TODO add ping command
    let options = parseOptions(prc)
    let name = if options.hasKey("name"):
            options["name"]
        else:
            prc.name().strVal()
    let guildID = if options.hasKey("guildid"):
            options["guildid"]
        else: ""
    slashCommand(prc, name, guildID)



macro command*(prc: untyped) =
    ## Use this pragma to add a command
    ##
    ## .. code-block::
    ##    proc ping() {.command.} =
    ##        # TODO add ping command
    ##
    ## By default the command uses the name of the proc has the command name e.g. the command defined before will be called ping.
    ## If you wish to give the command a different name then you must use the doc option $name
    ##
    ## .. code-block::
    ##    proc genericCommand() {.command.} =
    ##        ## $name: ping
    ##        # TODO add ping command
    
    let options = parseOptions(prc)
    let name = if options.hasKey("name"):
            options["name"]
        else:
            prc.name().strVal()
    command(prc, name)

macro ncommand*(name: string, prc: untyped) {.deprecated: "Use doc options instead"}=
    ## Use this pragma to add a command with a different name to the proc
    ##
    ## .. code-block::
    ##    proc cmdPing() {.ncommand(name = "ping").} =
    ##        # TODO add ping command
    ##
    command(prc, name.strVal())

proc getStrScanSymbol(typ: string): string =
    ## Gets the symbol that strscan uses in order to parse something of a certain type
    case typ:
        of "int": "$i"
        of "string": "$w"
        of "Channel": "#$w>"
        else: ""

proc addParameterParseCode(prc: NimNode, parameters: seq[ProcParameter]): NimNode =
    ## **INTERNAL**
    ## This injects code to the start of a block of code which will parse cmdInput and set the variables for the different parameters
    ## Currently it only supports int and string parameter types
    ## This is achieved with the strscans module
    if len(parameters) == 0: return prc # Don't inject code if there is nothing to parse
    result = newStmtList()
    var scanPattern: string
    # Add all the variables which will be filled with the scan
    for parameter in parameters:
        scanPattern &= getStrScanSymbol(parameter[1]) & " " # Add a space since the parameters are seperated by a space
        case parameter[1]:
            of "Channel":
                result.add parseExpr fmt"var {parameter[0]}: string"
            else:
                result.add parseExpr fmt"var {parameter[0]}: {parameter[1]}"
    scanPattern = scanPattern.strip()  # Remove final space so that it matches properly
    # Add in the scanning code
    var scanfCall = nnkCall.newTree(
        ident("scanf"),
        ident("cmdInput"),
        newLit(scanPattern)
    )
    for parameter in parameters:
        scanfCall.add ident(parameter[0])
    result.add quote do:
        if `scanfCall`:
            `prc`

macro buildCommandTree*(): untyped =
    ## **INTERNAL**
    ##
    ## Builds a case stmt with all the dimscordCommands.
    ## It requires that cmdName and cmdInput are both defined in the scope that it is called in
    ## This is handled by the library and the user does not need to worry about it
    ##
    ## * cmdName is the parsed name of the command that the user has sent
    ## * cmdInput is the extra info that the user has sent along with the string
    if dimscordCommands.len() == 0: return
    result = nnkCaseStmt.newTree(ident("cmdName"))
    for command in dimscordCommands:
        result.add nnkOfBranch.newTree(
            newStrLitNode(command.name),
            command.prc.addParameterParseCode(command.parameters)
        )

proc registerCommands*(api: RestApi, applicationID: string) {.async.} =
    ## Registers all the defined commands
    let 
        oldCommands = await api.getApplicationCommands(applicationID)
        commandNames = collect(newSeq) do:
            for command in dimscordSlashCommands:
                command.name

    var currentCommands: seq[tuple[name, description, id: string]] = @[] # Name, Description, Command ID
    # TODO clean this loop spaget
    for command in oldCommands:
        # Loop over all the commands that are currently registered
        # Delete them if they are not present in the code
        # Else add them to a list of current commands to compare against the code to see if a command needs to be updated or registered
        if not (command.name in commandNames):
            echo "Removing command ", command.name
            await api.deleteApplicationCommand(applicationID, command.id)
        else:
            currentCommands &= (command.name, command.description, command.id)
            
    for command in dimscordSlashCommands:
        var commandRegistered = false # Used to check later if the command is already registered
        for curCommand in currentCommands:
            if curCommand.name == command.name and curCommand.description != command.description:
                commandRegistered = true
                echo "Editing ", curCommand
                discard await api.editApplicationCommand(applicationID, curCommand.id, name = command.name, description = command.description, guildID = command.guildID)

        if not commandRegistered:
            echo "Registering ", command
            discard await api.registerApplicationCommand(applicationID, name = command.name, description = command.description, guildID = command.guildID)
            
proc generateHelpMsg(): string {.compileTime.} =
    ## Generates the help message for the bot
    ## The help string for each command is retrieved from the doc string in the proc
    for command in dimscordCommands:
        if command.help != "":
            result.add fmt"{command.name}: {command.help}"

proc findTokens(input: string, startPosition: int = 0): seq[string] =
    ## Finds all the tokens in a string
    ## A token can be a word, character, integer or a combination of them
    ## This helps with parseing a command from the user that might have irregular use of whitespace
    var position = startPosition
    while position < len(input):
        ## Skip past any whitespace
        position += skipWhitespace(input, start = position)
        ## Parse the token that comes after all the whitespace
        var nextToken: string
        let tokenLen = parseUntil(input, nextToken, until = " ",start = position)
        if tokenLen != 0: # If tokenLen is zero then it means there is a parsing error, most likely the end of the string
            position += tokenLen
            result   &= nextToken
        else:
            break

proc getCommandComponents(prefix, message: string): tuple[name: string, input: string] =
    ## Finds the two components of a command.
    ## This will be altered later once subgroups/subcommands are implemented.
    if message.startsWith(prefix):
        let tokens = findTokens(message, len(prefix))
        if tokens.len == 0: return # Return empty if nothing is found
        result.name = tokens[0]
        if tokens.len >= 1: # Only set input if there are more tokens
            result.input = tokens[1..^1].join(" ")

template slashCommandHandler*(i: Interaction) =
    if i.data.isSome():
        echo i.data.get().name

template commandHandler*(prefix: string, m: Message) =
    ## This is placed inside your message_create event like so
    ##
    ## .. code-block::
    ##    discord.events.message_create = proc (s: Shard , m: Message) {.async.} =
    ##        commandHandler("$$", m)
    ##
    # This is a template since buildCommandTree has to be run after all the commands have been added

    if m.content.startsWith(prefix):  # Dont waste time if it doesn't even have the prefix
        let
            cmdComponents = getCommandComponents(prefix, m.content)
            cmdName {.inject.} = cmdComponents.name.toLowerAscii()
            cmdInput {.inject.} = cmdComponents.input
        if cmdName == "":
            break
        buildCommandTree()

template commandHandler*(i: Interaction) =
    discard

export parseutils
export strscans
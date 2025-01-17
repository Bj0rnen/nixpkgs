{ config, lib, pkgs, ... }:

with lib;

let

  mainCfg = config.services.httpd;

  httpd = mainCfg.package;

  version24 = !versionOlder httpd.version "2.4";

  httpdConf = mainCfg.configFile;

  php = pkgs.php.override { apacheHttpd = httpd; };

  getPort = cfg: if cfg.port != 0 then cfg.port else if cfg.enableSSL then 443 else 80;

  extraModules = attrByPath ["extraModules"] [] mainCfg;
  extraForeignModules = filter isAttrs extraModules;
  extraApacheModules = filter isString extraModules;


  makeServerInfo = cfg: {
    # Canonical name must not include a trailing slash.
    canonicalName =
      (if cfg.enableSSL then "https" else "http") + "://" +
      cfg.hostName +
      (if getPort cfg != (if cfg.enableSSL then 443 else 80) then ":${toString (getPort cfg)}" else "");

    # Admin address: inherit from the main server if not specified for
    # a virtual host.
    adminAddr = if cfg.adminAddr != null then cfg.adminAddr else mainCfg.adminAddr;

    vhostConfig = cfg;
    serverConfig = mainCfg;
    fullConfig = config; # machine config
  };


  allHosts = [mainCfg] ++ mainCfg.virtualHosts;


  callSubservices = serverInfo: defs:
    let f = svc:
      let
        svcFunction =
          if svc ? function then svc.function
          else import (toString "${toString ./.}/${if svc ? serviceType then svc.serviceType else svc.serviceName}.nix");
        config = (evalModules
          { modules = [ { options = res.options; config = svc.config or svc; } ];
            check = false;
          }).config;
        defaults = {
          extraConfig = "";
          extraModules = [];
          extraModulesPre = [];
          extraPath = [];
          extraServerPath = [];
          globalEnvVars = [];
          robotsEntries = "";
          startupScript = "";
          enablePHP = false;
          phpOptions = "";
          options = {};
          documentRoot = null;
        };
        res = defaults // svcFunction { inherit config lib pkgs serverInfo php; };
      in res;
    in map f defs;


  # !!! callSubservices is expensive
  subservicesFor = cfg: callSubservices (makeServerInfo cfg) cfg.extraSubservices;

  mainSubservices = subservicesFor mainCfg;

  allSubservices = mainSubservices ++ concatMap subservicesFor mainCfg.virtualHosts;


  # !!! should be in lib
  writeTextInDir = name: text:
    pkgs.runCommand name {inherit text;} "mkdir -p $out; echo -n \"$text\" > $out/$name";


  enableSSL = any (vhost: vhost.enableSSL) allHosts;


  # Names of modules from ${httpd}/modules that we want to load.
  apacheModules =
    [ # HTTP authentication mechanisms: basic and digest.
      "auth_basic" "auth_digest"

      # Authentication: is the user who he claims to be?
      "authn_file" "authn_dbm" "authn_anon"
      (if version24 then "authn_core" else "authn_alias")

      # Authorization: is the user allowed access?
      "authz_user" "authz_groupfile" "authz_host"

      # Other modules.
      "ext_filter" "include" "log_config" "env" "mime_magic"
      "cern_meta" "expires" "headers" "usertrack" /* "unique_id" */ "setenvif"
      "mime" "dav" "status" "autoindex" "asis" "info" "dav_fs"
      "vhost_alias" "negotiation" "dir" "imagemap" "actions" "speling"
      "userdir" "alias" "rewrite" "proxy" "proxy_http"
    ]
    ++ optionals version24 [
      "mpm_${mainCfg.multiProcessingModule}"
      "authz_core"
      "unixd"
      "cache" "cache_disk"
      "slotmem_shm"
      "socache_shmcb"
      # For compatibility with old configurations, the new module mod_access_compat is provided.
      "access_compat"
    ]
    ++ (if mainCfg.multiProcessingModule == "prefork" then [ "cgi" ] else [ "cgid" ])
    ++ optional enableSSL "ssl"
    ++ optional mainCfg.enableCompression "deflate"
    ++ extraApacheModules;


  allDenied = if version24 then ''
    Require all denied
  '' else ''
    Order deny,allow
    Deny from all
  '';

  allGranted = if version24 then ''
    Require all granted
  '' else ''
    Order allow,deny
    Allow from all
  '';


  loggingConf = (if mainCfg.logFormat != "none" then ''
    ErrorLog ${mainCfg.logDir}/error_log

    LogLevel notice

    LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
    LogFormat "%h %l %u %t \"%r\" %>s %b" common
    LogFormat "%{Referer}i -> %U" referer
    LogFormat "%{User-agent}i" agent

    CustomLog ${mainCfg.logDir}/access_log ${mainCfg.logFormat}
  '' else ''
    ErrorLog /dev/null
  '');


  browserHacks = ''
    BrowserMatch "Mozilla/2" nokeepalive
    BrowserMatch "MSIE 4\.0b2;" nokeepalive downgrade-1.0 force-response-1.0
    BrowserMatch "RealPlayer 4\.0" force-response-1.0
    BrowserMatch "Java/1\.0" force-response-1.0
    BrowserMatch "JDK/1\.0" force-response-1.0
    BrowserMatch "Microsoft Data Access Internet Publishing Provider" redirect-carefully
    BrowserMatch "^WebDrive" redirect-carefully
    BrowserMatch "^WebDAVFS/1.[012]" redirect-carefully
    BrowserMatch "^gnome-vfs" redirect-carefully
  '';


  sslConf = ''
    SSLSessionCache ${if version24 then "shmcb" else "shm"}:${mainCfg.stateDir}/ssl_scache(512000)

    ${if version24 then "Mutex" else "SSLMutex"} posixsem

    SSLRandomSeed startup builtin
    SSLRandomSeed connect builtin

    SSLProtocol All -SSLv2 -SSLv3
    SSLCipherSuite HIGH:MEDIUM:!aNULL:!MD5:!EXP
  '';

  # From http://paulstamatiou.com/how-to-optimize-your-apache-site-with-mod-deflate/
  compressConf = ''
    SetOutputFilter DEFLATE

    # Don't compress binaries
    SetEnvIfNoCase Request_URI .(?:exe|t?gz|zip|iso|tar|bz2|sit|rar) no-gzip dont-vary
    # Don't compress images
    SetEnvIfNoCase Request_URI .(?:gif|jpe?g|jpg|ico|png)  no-gzip dont-vary
    # Don't compress PDFs
    SetEnvIfNoCase Request_URI .pdf no-gzip dont-vary
    # Don't compress flash files (only relevant if you host your own videos)
    SetEnvIfNoCase Request_URI .flv no-gzip dont-vary
    # Netscape 4.X has some problems
    BrowserMatch ^Mozilla/4 gzip-only-text/html
    # Netscape 4.06-4.08 have some more problems
    BrowserMatch ^Mozilla/4.0[678] no-gzip
    # MSIE masquerades as Netscape, but it is fine
    BrowserMatch \bMSIE !no-gzip !gzip-only-text/html
    # Make sure proxies don't deliver the wrong content
    Header append Vary User-Agent env=!dont-vary
  '';

  mimeConf = ''
    TypesConfig ${httpd}/conf/mime.types

    AddType application/x-x509-ca-cert .crt
    AddType application/x-pkcs7-crl    .crl
    AddType application/x-httpd-php    .php .phtml

    <IfModule mod_mime_magic.c>
        MIMEMagicFile ${httpd}/conf/magic
    </IfModule>
  '';


  perServerConf = isMainServer: cfg: let

    serverInfo = makeServerInfo cfg;

    subservices = callSubservices serverInfo cfg.extraSubservices;

    maybeDocumentRoot = fold (svc: acc:
      if acc == null then svc.documentRoot else assert svc.documentRoot == null; acc
    ) null ([ cfg ] ++ subservices);

    documentRoot = if maybeDocumentRoot != null then maybeDocumentRoot else
      pkgs.runCommand "empty" {} "mkdir -p $out";

    documentRootConf = ''
      DocumentRoot "${documentRoot}"

      <Directory "${documentRoot}">
          Options Indexes FollowSymLinks
          AllowOverride None
          ${allGranted}
      </Directory>
    '';

    robotsTxt =
      concatStringsSep "\n" (filter (x: x != "") (
        # If this is a vhost, the include the entries for the main server as well.
        (if isMainServer then [] else [mainCfg.robotsEntries] ++ map (svc: svc.robotsEntries) mainSubservices)
        ++ [cfg.robotsEntries]
        ++ (map (svc: svc.robotsEntries) subservices)));

  in ''
    ServerName ${serverInfo.canonicalName}

    ${concatMapStrings (alias: "ServerAlias ${alias}\n") cfg.serverAliases}

    ${if cfg.sslServerCert != null then ''
      SSLCertificateFile ${cfg.sslServerCert}
      SSLCertificateKeyFile ${cfg.sslServerKey}
      ${if cfg.sslServerChain != null then ''
        SSLCertificateChainFile ${cfg.sslServerChain}
      '' else ""}
    '' else ""}

    ${if cfg.enableSSL then ''
      SSLEngine on
    '' else if enableSSL then /* i.e., SSL is enabled for some host, but not this one */
    ''
      SSLEngine off
    '' else ""}

    ${if isMainServer || cfg.adminAddr != null then ''
      ServerAdmin ${cfg.adminAddr}
    '' else ""}

    ${if !isMainServer && mainCfg.logPerVirtualHost then ''
      ErrorLog ${mainCfg.logDir}/error_log-${cfg.hostName}
      CustomLog ${mainCfg.logDir}/access_log-${cfg.hostName} ${cfg.logFormat}
    '' else ""}

    ${optionalString (robotsTxt != "") ''
      Alias /robots.txt ${pkgs.writeText "robots.txt" robotsTxt}
    ''}

    ${if isMainServer || maybeDocumentRoot != null then documentRootConf else ""}

    ${if cfg.enableUserDir then ''

      UserDir public_html
      UserDir disabled root

      <Directory "/home/*/public_html">
          AllowOverride FileInfo AuthConfig Limit Indexes
          Options MultiViews Indexes SymLinksIfOwnerMatch IncludesNoExec
          <Limit GET POST OPTIONS>
              ${allGranted}
          </Limit>
          <LimitExcept GET POST OPTIONS>
              ${allDenied}
          </LimitExcept>
      </Directory>

    '' else ""}

    ${if cfg.globalRedirect != null && cfg.globalRedirect != "" then ''
      RedirectPermanent / ${cfg.globalRedirect}
    '' else ""}

    ${
      let makeFileConf = elem: ''
            Alias ${elem.urlPath} ${elem.file}
          '';
      in concatMapStrings makeFileConf cfg.servedFiles
    }

    ${
      let makeDirConf = elem: ''
            Alias ${elem.urlPath} ${elem.dir}/
            <Directory ${elem.dir}>
                Options +Indexes
                ${allGranted}
                AllowOverride All
            </Directory>
          '';
      in concatMapStrings makeDirConf cfg.servedDirs
    }

    ${concatMapStrings (svc: svc.extraConfig) subservices}

    ${cfg.extraConfig}
  '';


  confFile = pkgs.writeText "httpd.conf" ''

    ServerRoot ${httpd}

    ${optionalString version24 ''
      DefaultRuntimeDir ${mainCfg.stateDir}/runtime
    ''}

    PidFile ${mainCfg.stateDir}/httpd.pid

    ${optionalString (mainCfg.multiProcessingModule != "prefork") ''
      # mod_cgid requires this.
      ScriptSock ${mainCfg.stateDir}/cgisock
    ''}

    <IfModule prefork.c>
        MaxClients           ${toString mainCfg.maxClients}
        MaxRequestsPerChild  ${toString mainCfg.maxRequestsPerChild}
    </IfModule>

    ${let
        ports = map getPort allHosts;
        uniquePorts = uniqList {inputList = ports;};
      in concatMapStrings (port: "Listen ${toString port}\n") uniquePorts
    }

    User ${mainCfg.user}
    Group ${mainCfg.group}

    ${let
        load = {name, path}: "LoadModule ${name}_module ${path}\n";
        allModules =
          concatMap (svc: svc.extraModulesPre) allSubservices
          ++ map (name: {inherit name; path = "${httpd}/modules/mod_${name}.so";}) apacheModules
          ++ optional enablePHP { name = "php5"; path = "${php}/modules/libphp5.so"; }
          ++ concatMap (svc: svc.extraModules) allSubservices
          ++ extraForeignModules;
      in concatMapStrings load allModules
    }

    AddHandler type-map var

    <Files ~ "^\.ht">
        ${allDenied}
    </Files>

    ${mimeConf}
    ${loggingConf}
    ${browserHacks}
    ${optionalString mainCfg.enableCompression compressConf}

    Include ${httpd}/conf/extra/httpd-default.conf
    Include ${httpd}/conf/extra/httpd-autoindex.conf
    Include ${httpd}/conf/extra/httpd-multilang-errordoc.conf
    Include ${httpd}/conf/extra/httpd-languages.conf

    ${if enableSSL then sslConf else ""}

    # Fascist default - deny access to everything.
    <Directory />
        Options FollowSymLinks
        AllowOverride None
        ${allDenied}
    </Directory>

    # But do allow access to files in the store so that we don't have
    # to generate <Directory> clauses for every generated file that we
    # want to serve.
    <Directory /nix/store>
        ${allGranted}
    </Directory>

    # Generate directives for the main server.
    ${perServerConf true mainCfg}

    # Always enable virtual hosts; it doesn't seem to hurt.
    ${let
        ports = map getPort allHosts;
        uniquePorts = uniqList {inputList = ports;};
        directives = concatMapStrings (port: "NameVirtualHost *:${toString port}\n") uniquePorts;
      in optionalString (!version24) directives
    }

    ${let
        makeVirtualHost = vhost: ''
          <VirtualHost *:${toString (getPort vhost)}>
              ${perServerConf false vhost}
          </VirtualHost>
        '';
      in concatMapStrings makeVirtualHost mainCfg.virtualHosts
    }
  '';


  enablePHP = mainCfg.enablePHP || any (svc: svc.enablePHP) allSubservices;


  # Generate the PHP configuration file.  Should probably be factored
  # out into a separate module.
  phpIni = pkgs.runCommand "php.ini"
    { options = concatStringsSep "\n"
        ([ mainCfg.phpOptions ] ++ (map (svc: svc.phpOptions) allSubservices));
    }
    ''
      cat ${php}/etc/php-recommended.ini > $out
      echo "$options" >> $out
    '';

in


{

  ###### interface

  options = {

    services.httpd = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the Apache HTTP Server.";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.apacheHttpd;
        description = ''
          Overridable attribute of the Apache HTTP Server package to use.
        '';
      };

      configFile = mkOption {
        type = types.path;
        default = confFile;
        example = literalExample ''pkgs.writeText "httpd.conf" "# my custom config file ...";'';
        description = ''
          Override the configuration file used by Apache. By default,
          NixOS generates one automatically.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Cnfiguration lines appended to the generated Apache
          configuration file. Note that this mechanism may not work
          when <option>configFile</option> is overridden.
        '';
      };

      extraModules = mkOption {
        type = types.listOf types.unspecified;
        default = [];
        example = literalExample ''[ "proxy_connect" { name = "php5"; path = "''${pkgs.php}/modules/libphp5.so"; } ]'';
        description = ''
          Additional Apache modules to be used.  These can be
          specified as a string in the case of modules distributed
          with Apache, or as an attribute set specifying the
          <varname>name</varname> and <varname>path</varname> of the
          module.
        '';
      };

      logPerVirtualHost = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If enabled, each virtual host gets its own
          <filename>access_log</filename> and
          <filename>error_log</filename>, namely suffixed by the
          <option>hostName</option> of the virtual host.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "wwwrun";
        description = ''
          User account under which httpd runs.  The account is created
          automatically if it doesn't exist.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "wwwrun";
        description = ''
          Group under which httpd runs.  The account is created
          automatically if it doesn't exist.
        '';
      };

      logDir = mkOption {
        type = types.path;
        default = "/var/log/httpd";
        description = ''
          Directory for Apache's log files.  It is created automatically.
        '';
      };

      stateDir = mkOption {
        type = types.path;
        default = "/run/httpd";
        description = ''
          Directory for Apache's transient runtime state (such as PID
          files).  It is created automatically.  Note that the default,
          <filename>/run/httpd</filename>, is deleted at boot time.
        '';
      };

      virtualHosts = mkOption {
        type = types.listOf (types.submodule (
          { options = import ./per-server-options.nix {
              inherit lib;
              forMainServer = false;
            };
          }));
        default = [];
        example = [
          { hostName = "foo";
            documentRoot = "/data/webroot-foo";
          }
          { hostName = "bar";
            documentRoot = "/data/webroot-bar";
          }
        ];
        description = ''
          Specification of the virtual hosts served by Apache.  Each
          element should be an attribute set specifying the
          configuration of the virtual host.  The available options
          are the non-global options permissible for the main host.
        '';
      };

      enablePHP = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable the PHP module.";
      };

      phpOptions = mkOption {
        type = types.lines;
        default = "";
        example =
          ''
            date.timezone = "CET"
          '';
        description =
          "Options appended to the PHP configuration file <filename>php.ini</filename>.";
      };

      multiProcessingModule = mkOption {
        type = types.str;
        default = "prefork";
        example = "worker";
        description =
          ''
            Multi-processing module to be used by Apache.  Available
            modules are <literal>prefork</literal> (the default;
            handles each request in a separate child process),
            <literal>worker</literal> (hybrid approach that starts a
            number of child processes each running a number of
            threads) and <literal>event</literal> (a recent variant of
            <literal>worker</literal> that handles persistent
            connections more efficiently).
          '';
      };

      maxClients = mkOption {
        type = types.int;
        default = 150;
        example = 8;
        description = "Maximum number of httpd processes (prefork)";
      };

      maxRequestsPerChild = mkOption {
        type = types.int;
        default = 0;
        example = 500;
        description =
          "Maximum number of httpd requests answered per httpd child (prefork), 0 means unlimited";
      };

      enableCompression = mkOption {
        type = types.bool;
        default = false;
        description = "Enable compression of responses using mod_deflate.";
      };
    }

    # Include the options shared between the main server and virtual hosts.
    // (import ./per-server-options.nix {
      inherit lib;
      forMainServer = true;
    });

  };


  ###### implementation

  config = mkIf config.services.httpd.enable {

    assertions = [ { assertion = mainCfg.enableSSL == true
                               -> mainCfg.sslServerCert != null
                                    && mainCfg.sslServerKey != null;
                     message = "SSL is enabled for httpd, but sslServerCert and/or sslServerKey haven't been specified."; }
                 ];

    users.extraUsers = optionalAttrs (mainCfg.user == "wwwrun") (singleton
      { name = "wwwrun";
        group = mainCfg.group;
        description = "Apache httpd user";
        uid = config.ids.uids.wwwrun;
      });

    users.extraGroups = optionalAttrs (mainCfg.group == "wwwrun") (singleton
      { name = "wwwrun";
        gid = config.ids.gids.wwwrun;
      });

    environment.systemPackages = [httpd] ++ concatMap (svc: svc.extraPath) allSubservices;

    services.httpd.phpOptions =
      ''
        ; Needed for PHP's mail() function.
        sendmail_path = sendmail -t -i

        ; Apparently PHP doesn't use $TZ.
        date.timezone = "${config.time.timeZone}"
      '';

    systemd.services.httpd =
      { description = "Apache HTTPD";

        wantedBy = [ "multi-user.target" ];
        wants = [ "keys.target" ];
        after = [ "network.target" "fs.target" "postgresql.service" "keys.target" ];

        path =
          [ httpd pkgs.coreutils pkgs.gnugrep ]
          ++ # Needed for PHP's mail() function.  !!! Probably the
             # ssmtp module should export the path to sendmail in
             # some way.
             optional config.networking.defaultMailServer.directDelivery pkgs.ssmtp
          ++ concatMap (svc: svc.extraServerPath) allSubservices;

        environment =
          optionalAttrs enablePHP { PHPRC = phpIni; }
          // (listToAttrs (concatMap (svc: svc.globalEnvVars) allSubservices));

        preStart =
          ''
            mkdir -m 0750 -p ${mainCfg.stateDir}
            [ $(id -u) != 0 ] || chown root.${mainCfg.group} ${mainCfg.stateDir}
            ${optionalString version24 ''
              mkdir -m 0750 -p "${mainCfg.stateDir}/runtime"
              [ $(id -u) != 0 ] || chown root.${mainCfg.group} "${mainCfg.stateDir}/runtime"
            ''}
            mkdir -m 0700 -p ${mainCfg.logDir}

            ${optionalString (mainCfg.documentRoot != null)
            ''
              # Create the document root directory if does not exists yet
              mkdir -p ${mainCfg.documentRoot}
            ''
            }

            # Get rid of old semaphores.  These tend to accumulate across
            # server restarts, eventually preventing it from restarting
            # successfully.
            for i in $(${pkgs.utillinux}/bin/ipcs -s | grep ' ${mainCfg.user} ' | cut -f2 -d ' '); do
                ${pkgs.utillinux}/bin/ipcrm -s $i
            done

            # Run the startup hooks for the subservices.
            for i in ${toString (map (svn: svn.startupScript) allSubservices)}; do
                echo Running Apache startup hook $i...
                $i
            done
          '';

        serviceConfig.ExecStart = "@${httpd}/bin/httpd httpd -f ${httpdConf}";
        serviceConfig.ExecStop = "${httpd}/bin/httpd -f ${httpdConf} -k graceful-stop";
        serviceConfig.Type = "forking";
        serviceConfig.PIDFile = "${mainCfg.stateDir}/httpd.pid";
        serviceConfig.Restart = "always";
        serviceConfig.RestartSec = "5s";
      };

  };

}

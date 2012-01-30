{- github-backup
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import qualified Data.Map as M
import qualified Data.Set as S
import System.Environment
import System.IO.Error (try)
import Control.Exception (bracket)
import Text.Show.Pretty
import Control.Monad.State.Strict
import qualified Github.Data.Readable as Github
import qualified Github.Repos as Github
import qualified Github.Repos.Forks as Github
import qualified Github.PullRequests as Github
import qualified Github.Repos.Watching as Github
import qualified Github.Issues as Github
import qualified Github.Issues.Comments
import qualified Github.Issues.Milestones

import Common
import Utility.State
import qualified Git
import qualified Git.Construct
import qualified Git.Config
import qualified Git.Types
import qualified Git.Command
import qualified Git.Ref
import qualified Git.Branch

-- A github user and repo.
data GithubUserRepo = GithubUserRepo String String
	deriving (Eq, Show, Read, Ord)

toGithubUserRepo :: Github.Repo -> GithubUserRepo
toGithubUserRepo r = GithubUserRepo 
	(Github.githubUserLogin $ Github.repoOwner r)
	(Github.repoName r)

repoUrl :: GithubUserRepo -> String
repoUrl (GithubUserRepo user remote) =
	"git://github.com/" ++ user ++ "/" ++ remote ++ ".git"

repoWikiUrl :: GithubUserRepo -> String
repoWikiUrl (GithubUserRepo user remote) =
	"git://github.com/" ++ user ++ "/" ++ remote ++ ".wiki.git"

-- A name for a github api call.
type ApiName = String

-- A request to make of github. It may have an extra parameter.
data RequestBase = RequestBase ApiName GithubUserRepo
	deriving (Eq, Show, Read, Ord)
data Request = RequestSimple RequestBase
	| RequestNum RequestBase Int
	deriving (Eq, Show, Read, Ord)

requestRepo :: Request -> GithubUserRepo
requestRepo (RequestSimple (RequestBase _ repo)) = repo
requestRepo (RequestNum (RequestBase _ repo) _) = repo

data BackupState = BackupState
	{ failedRequests :: S.Set Request
	, retriedRequests :: S.Set Request
	, backupRepo :: Git.Repo
	}

{- Our monad. -}
newtype Backup a = Backup { runBackup :: StateT BackupState IO a }
	deriving (
		Monad,
		MonadState BackupState,
		MonadIO,
		Functor,
		Applicative
	)

inRepo :: (Git.Repo -> IO a) -> Backup a
inRepo a = liftIO . a =<< getState backupRepo

failedRequest :: Request -> Github.Error-> Backup ()
failedRequest req e = unless (ignorable e) $ do
	set <- getState failedRequests
	changeState $ \s -> s { failedRequests = S.insert req set }
	where
		ignorable (Github.JsonError m) =
			"disabled for this repo" `isInfixOf` m
		ignorable _ = False

runRequest :: Request -> Backup ()
runRequest req@(RequestSimple base) = runRequest' base req
runRequest req@(RequestNum base _) = runRequest' base req
runRequest' :: RequestBase -> Request -> Backup ()
runRequest' base req = do
	-- avoid re-running requests that were already retried
	retried <- getState retriedRequests
	if S.member req retried
		then return ()
		else (lookupApi base) req

type Storer = Request -> Backup ()
data ApiListItem = ApiListItem ApiName Storer Bool
apiList :: [ApiListItem]
apiList = 
	[ ApiListItem "userrepo" userrepoStore True
	, ApiListItem "watchers" watchersStore True
	, ApiListItem "pullrequests" pullrequestsStore True
	, ApiListItem "pullrequest" pullrequestStore False
	, ApiListItem "milestones" milestonesStore True
	, ApiListItem "issues" issuesStore True
	, ApiListItem "issuecomments" issuecommentsStore False
	-- comes last because it recurses on to the forks
	, ApiListItem "forks" forksStore True
	]

{- Map of Github api calls we can make to store their data. -}
api :: M.Map ApiName Storer
api = M.fromList $ map (\(ApiListItem n s _) -> (n, s)) apiList

{- List of toplevel api calls that are followed to get all data. -}
toplevelApi :: [ApiName]
toplevelApi = map (\(ApiListItem n _ _) -> n) $
	filter (\(ApiListItem _ _ toplevel) -> toplevel) apiList

lookupApi :: RequestBase -> Storer
lookupApi (RequestBase name _) = fromMaybe bad $ M.lookup name api
	where
		bad = error $ "internal error: bad api call: " ++ name

userrepoStore :: Storer
userrepoStore = simpleHelper Github.userRepo $ \req r -> do
	when (Github.repoHasWiki r == Just True) $
		updateWiki $ toGithubUserRepo r
	store "repo" req r

watchersStore :: Storer
watchersStore = simpleHelper Github.watchersFor $ storeSorted "watchers"

pullrequestsStore :: Storer
pullrequestsStore = simpleHelper Github.pullRequestsFor $
	forValues $ \req r -> do
		let repo = requestRepo req
		let n = Github.pullRequestNumber r
		runRequest $ RequestNum (RequestBase "pullrequest" repo) n

pullrequestStore :: Storer
pullrequestStore = numHelper Github.pullRequest $ \n ->
	store ("pullrequest" </> show n)

milestonesStore :: Storer
milestonesStore = simpleHelper Github.Issues.Milestones.milestones $
	forValues $ \req m -> do
		let n = Github.milestoneNumber m
		store ("milestone" </> show n) req m

issuesStore :: Storer
issuesStore = withHelper Github.issuesForRepo [] $ forValues $ \req i -> do
	let repo = requestRepo req
	let n = Github.issueNumber i
	store ("issue" </> show n) req i
	runRequest (RequestNum (RequestBase "issuecomments" repo) n)

issuecommentsStore :: Storer
issuecommentsStore = numHelper Github.Issues.Comments.comments $ \n ->
	forValues $ \req c -> do
		let i = Github.issueCommentId c
		store ("issue" </> show n ++ "_comment" </> show i) req c

forksStore :: Storer
forksStore = simpleHelper Github.forksFor $ \req fs -> do
	storeSorted "forks" req fs
	mapM_ (traverse . toGithubUserRepo) fs
	where
		traverse fork = whenM (addFork fork) $
			gatherMetaData fork

forValues :: (Request -> v -> Backup ()) -> Request -> [v] -> Backup ()
forValues handle req vs = forM_ vs (handle req)

type ApiCall v = String -> String -> IO (Either Github.Error v)
type ApiWith v b = String -> String -> b -> IO (Either Github.Error v)
type ApiNum v = ApiWith v Int
type Handler v = Request -> v -> Backup ()
type Helper = Request -> Backup ()

simpleHelper :: ApiCall v -> Handler v -> Helper
simpleHelper call handle req@(RequestSimple (RequestBase _ (GithubUserRepo user repo))) =
	go =<< liftIO (call user repo)
	where
		go (Left e) = failedRequest req e
		go (Right v) = handle req v
simpleHelper _ _ r = badRequest r

withHelper :: ApiWith v b -> b -> Handler v -> Helper
withHelper call b handle req@(RequestSimple (RequestBase _ (GithubUserRepo user repo))) =
	go =<< liftIO (call user repo b)
	where
		go (Left e) = failedRequest req e
		go (Right v) = handle req v
withHelper _ _ _ r = badRequest r

numHelper :: ApiNum v -> (Int -> Handler v) -> Helper
numHelper call handle req@(RequestNum (RequestBase _ (GithubUserRepo user repo)) num) =
	go =<< liftIO (call user repo num)
	where
		go (Left e) = failedRequest req e
		go (Right v) = handle num req v
numHelper _ _ r = badRequest r

badRequest :: Request -> a
badRequest r = error $ "internal error: bad request type " ++ show r

store :: Show a => FilePath -> Request -> a -> Backup ()
store filebase req val = do
	file <- location (requestRepo req) <$> workDir
	liftIO $ do
		createDirectoryIfMissing True (parentDir file)
		writeFile file (ppShow val)
	where
		location (GithubUserRepo user repo) workdir =
			workdir </> user ++ "_" ++ repo </> filebase

workDir :: Backup FilePath
workDir = (</>)
		<$> (Git.gitDir <$> getState backupRepo)
		<*> pure "github-backup.tmp"

storeSorted :: Ord a => Show a => FilePath -> Request -> [a] -> Backup ()
storeSorted file req val = store file req (sort val)

gitHubRepos :: Backup [Git.Repo]
gitHubRepos = fst . unzip . gitHubPairs <$> getState backupRepo

gitHubRemotes :: Backup [GithubUserRepo]
gitHubRemotes = snd . unzip . gitHubPairs <$> getState backupRepo

gitHubPairs :: Git.Repo -> [(Git.Repo, GithubUserRepo)]
gitHubPairs = filter (not . wiki ) . mapMaybe check . Git.Types.remotes
	where
		check r@Git.Repo { Git.Types.location = Git.Types.Url u } =
			headMaybe $ mapMaybe (checkurl r $ show u) gitHubUrlPrefixes
		check _ = Nothing
		checkurl r u prefix
			| prefix `isPrefixOf` u && length bits == 2 =
				Just $ (r,
					GithubUserRepo (bits !! 0)
						(dropdotgit $ bits !! 1))
			| otherwise = Nothing
			where
				rest = drop (length prefix) u
				bits = split "/" rest
		dropdotgit s
			| ".git" `isSuffixOf` s = take (length s - length ".git") s
			| otherwise = s
		wiki (_, GithubUserRepo _ u) = ".wiki" `isSuffixOf` u

{- All known prefixes for urls to github repos. -}
gitHubUrlPrefixes :: [String]
gitHubUrlPrefixes = 
	[ "git@github.com:"
	, "git://github.com/"
	, "https://github.com/"
	, "http://github.com/"
	, "ssh://git@github.com/~/"
	]

onGithubBranch :: Git.Repo -> IO () -> IO ()
onGithubBranch r a = bracket prep cleanup (const a)
	where
		prep = do
			oldbranch <- Git.Branch.current r
			when (oldbranch == Just branchref) $
				error $ "it's not currently safe to run github-backup while the " ++
					branchname ++ " branch is checked out!"
			exists <- Git.Ref.matching branchref r
			if null exists
				then checkout [Param "--orphan", Param branchname]
				else checkout [Param branchname]
			return oldbranch
		cleanup Nothing = return ()
		cleanup (Just oldbranch)
			| name == branchname = return ()
			| otherwise = checkout [Param "--force", Param name]
			where
				name = show $ Git.Ref.base oldbranch
		checkout params = Git.Command.run "checkout" (Param "-q" : params) r
		branchname = "github"
		branchref = Git.Ref $ "refs/heads/" ++ branchname

{- Commits all files in the workDir into git, and deletes it. -}
commitWorkDir :: Backup ()
commitWorkDir = do
	dir <- workDir
	r <- getState backupRepo
	liftIO $ whenM (doesDirectoryExist dir) $ onGithubBranch r $ do
		_ <- boolSystem "git"
			[Param "--work-tree", File dir, Param "add", Param "."]
		_ <- boolSystem "git"
			[Param "--work-tree", File dir, Param "commit",
			 Param "-a", Param "-m", Param "github-backup"]
		removeDirectoryRecursive dir

updateWiki :: GithubUserRepo -> Backup ()
updateWiki fork = do
	remotes <- Git.remotes <$> getState backupRepo
	if (null $ filter (\r -> Git.remoteName r == Just remote) remotes)
		then do
			-- github often does not really have a wiki,
			-- don't bloat config if there is none
			unlessM (addRemote remote $ repoWikiUrl fork) $ do
				removeRemote remote
			return ()
		else do
			_ <- fetchwiki
			return ()
	where
		fetchwiki = inRepo $ Git.Command.runBool "fetch" [Param remote]
		remote = remoteFor fork
		remoteFor (GithubUserRepo user repo) =
			"github_" ++ user ++ "_" ++ repo ++ ".wiki"

addFork :: GithubUserRepo -> Backup Bool
addFork fork = do
	remotes <- gitHubRemotes
	if (fork `elem` remotes)
		then return False
		else do
			liftIO $ putStrLn $ "New fork: " ++ repoUrl fork
			_ <- addRemote (remoteFor fork) (repoUrl fork)
			return True
	where
		remoteFor (GithubUserRepo user repo) =
			"github_" ++ user ++ "_" ++ repo

{- Adds a remote, also fetching from it. -}
addRemote :: String -> String -> Backup Bool
addRemote remotename remoteurl =
	inRepo $ Git.Command.runBool "remote"
		[ Param "add"
		, Param "-f"
		, Param remotename
		, Param remoteurl
		]

removeRemote :: String -> Backup ()
removeRemote remotename = do
	_ <- inRepo $ Git.Command.runBool "remote"
		[ Param "rm"
		, Param remotename
		]
	return ()

{- Fetches from the github remote. Done by github-backup, just because
 - it would be weird for a backup to not fetch all available data.
 - Even though its real focus is on metadata not stored in git. -}
fetchRepo :: Git.Repo -> Backup Bool
fetchRepo repo = inRepo $
	Git.Command.runBool "fetch"
		[Param $ fromJust $ Git.Types.remoteName repo]

{- Gathers metadata for the repo. Retuns a list of files written
 - and a list that may contain requests that need to be retried later. -}
gatherMetaData :: GithubUserRepo -> Backup ()
gatherMetaData repo = do
	liftIO $ putStrLn $ "Gathering metadata for " ++ repoUrl repo ++ " ..."
	mapM_ call toplevelApi
	where
		call name = runRequest $
			RequestSimple $ RequestBase name repo

storeRetry :: [Request] -> Git.Repo -> IO ()
storeRetry [] r = do
	_ <- try $ removeFile (retryFile r)
	return ()
storeRetry retryrequests r = writeFile (retryFile r) (show retryrequests)

loadRetry :: Git.Repo -> IO [Request]
loadRetry r = do
	c <- catchMaybeIO (readFileStrict (retryFile r))
	case c of
		Nothing -> return []
		Just s -> case readish s of
			Nothing -> return []
			Just v -> return v

retryFile :: Git.Repo -> FilePath
retryFile r = Git.gitDir r </> "github-backup.todo"

retry :: Backup (S.Set Request)
retry = do
	todo <- inRepo $ loadRetry
	unless (null todo) $ do
		liftIO $ putStrLn $
			"Retrying " ++ show (length todo) ++
			" requests that failed last time..."
		mapM_ runRequest todo
	retriedfailed <- getState failedRequests
	changeState $ \s -> s
		{ failedRequests = S.empty
		, retriedRequests = S.fromList todo
		}
	return retriedfailed

backup :: Backup ()
backup = do
	retriedfailed <- retry
	remotes <- gitHubPairs <$> getState backupRepo
	when (null remotes) $ do
		error "no github remotes found"
	forM_ remotes $ \(repo, remote) -> do
		_ <- fetchRepo repo
		gatherMetaData remote
	save retriedfailed

{- Save all backup data. Files that were written to the workDir are committed.
 - Requests that failed are saved for next time. Requests that were retried
 - this time and failed are ordered last, to ensure that we don't get stuck
 - retrying the same requests and not making progress when run again.
 -}
save :: S.Set Request -> Backup ()
save retriedfailed = do
	commitWorkDir
	failed <- getState failedRequests
	let toretry = S.toList failed ++ S.toList retriedfailed
	inRepo $ storeRetry toretry
	unless (null toretry) $ do
		error $ "Backup may be incomplete; " ++
			show (length toretry) ++
			" requests failed. Run again later."

usage :: String
usage = "usage: github-backup [directory]"

getLocalRepo :: IO Git.Repo
getLocalRepo = getArgs >>= make >>= Git.Config.read
	where
		make [] = Git.Construct.fromCwd
		make (d:[]) = Git.Construct.fromPath d
		make _ = error usage

newState :: Git.Repo -> BackupState
newState = BackupState S.empty S.empty

main :: IO ()
main = evalStateT (runBackup backup) . newState =<< getLocalRepo
